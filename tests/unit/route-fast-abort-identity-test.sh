#!/usr/bin/env bash
# Tests: tests/lib/proc-identity.sh — process IDENTITY vs process liveness (#1949).
#
# WHY THIS FILE EXISTS. The caller, tests/integration/route-fast-abort-test.sh, is
# `skip_unless_platform linux` and every developer machine here is macOS, so it
# never runs locally. Two fixes to its leftover assertion (#1943 zombies, then the
# identity check) therefore shipped on reasoning rather than observation, and the
# first did not hold. A fixture procfs makes all five cases drivable anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "proc identity vs liveness (#1949)"
setup_test_env "zb-proc-identity"

NEEDLE="/tmp/zb-run-XYZ/bin/claude"
export _RFA_PROC="$TEST_TEMP_DIR/proc"
mkdir -p "$_RFA_PROC"
# shellcheck source=../lib/proc-identity.sh
source "$REPO_ROOT/tests/lib/proc-identity.sh"

# _mk <pid> <cmdline|__EMPTY__|__NOCMD__|__UNREADABLE__>
_mk() {
    local pid="$1" what="$2" d="$_RFA_PROC/$1"
    mkdir -p "$d"
    case "$what" in
        __NOCMD__)      : ;;                                   # dir, no cmdline file
        __EMPTY__)      : > "$d/cmdline" ;;
        __UNREADABLE__) printf 'x' > "$d/cmdline"; chmod 000 "$d/cmdline" ;;
        *)              printf '%s' "$what" > "$d/cmdline" ;;
    esac
}

print_test_section "[SPEC-1] the five cases"

# 1. /proc/<pid> absent -> gone -> do NOT count
if proc_is_my_process 9001 "$NEEDLE"; then
    assert_fail "[SPEC-1] absent /proc entry must not count"
else
    assert_pass "[SPEC-1] absent /proc entry -> not counted (process is gone)"
fi

# 2. cmdline present but EMPTY -> zombie (#1942) -> do NOT count
_mk 9002 __EMPTY__
if proc_is_my_process 9002 "$NEEDLE"; then
    assert_fail "[SPEC-1] a zombie (empty cmdline) must not count"
else
    assert_pass "[SPEC-1] zombie (empty cmdline) -> not counted (#1942)"
fi

# 3. cmdline non-empty but NOT ours -> PID reuse -> do NOT count
_mk 9003 "/usr/bin/some-unrelated-daemon --serve"
if proc_is_my_process 9003 "$NEEDLE"; then
    assert_fail "[SPEC-1] a recycled PID must not count as our leftover"
else
    assert_pass "[SPEC-1] PID reuse (stranger's cmdline) -> not counted"
fi

# 4. cmdline non-empty and OURS -> a real leftover -> COUNT
_mk 9004 "/bin/bash $NEEDLE --model x"
if proc_is_my_process 9004 "$NEEDLE"; then
    assert_pass "[SPEC-1] our stub, alive -> counted"
else
    assert_fail "[SPEC-1] a live stub of ours MUST be counted"
fi

# 5. dir exists, cmdline UNREADABLE -> ambiguous -> COUNT (fail CLOSED)
#    The whole point: a leak detector that skips what it cannot read has
#    stopped detecting.
_mk 9005 __UNREADABLE__
if [[ -r "$_RFA_PROC/9005/cmdline" ]]; then
    skip_test "[SPEC-1] unreadable-cmdline case (running as root: chmod 000 still readable)"
else
    if proc_is_my_process 9005 "$NEEDLE"; then
        assert_pass "[SPEC-1] unreadable cmdline -> counted (fails CLOSED, not open)"
    else
        assert_fail "[SPEC-1] unreadable cmdline must fail CLOSED and be counted"
    fi
fi
chmod 644 "$_RFA_PROC/9005/cmdline" 2>/dev/null || true

# 6. dir exists, no cmdline file at all -> same ambiguity -> COUNT
_mk 9006 __NOCMD__
if proc_is_my_process 9006 "$NEEDLE"; then
    assert_pass "[SPEC-1] missing cmdline file under a live dir -> counted (fails closed)"
else
    assert_fail "[SPEC-1] missing cmdline file must fail CLOSED and be counted"
fi

print_test_section "[SPEC-2][guard] refuses to answer without both inputs"
# A needle-less call would match EVERYTHING (`*""*` is always true), turning the
# check into "count every live PID". Refuse rather than answer wrongly.
_mk 9007 "/bin/bash $NEEDLE"
if proc_is_my_process 9007 ""; then
    assert_fail "[SPEC-2] an empty needle must not match"
else
    assert_pass "[SPEC-2] empty needle -> refused, not a universal match"
fi
if proc_is_my_process "" "$NEEDLE"; then
    assert_fail "[SPEC-2] an empty pid must not match"
else
    assert_pass "[SPEC-2] empty pid -> refused"
fi

print_test_section "[SPEC-3] the decision is a pure function of what was observed"
# WHY A PURE FUNCTION (#2020). This detector has now been fixed three times
# (#1942 zombies, #1949 PID identity, #1975 the window) and each fix was a guess,
# because the interesting states are RACES — a process on its way out — and a
# race cannot be staged in a fixture directory. Separating the DECISION from the
# OBSERVATIONS makes every state drivable by just writing the observations down,
# including the ones that only occur for a few microseconds on a loaded runner.
#
# proc_classify <present_before> <read_ok> <cmdline> <needle> <present_after>
#   -> prints one of: gone | zombie | stranger | ours | unprovable
#   -> exit 0 when the process should be COUNTED as a leftover, 1 when not.

_c() { proc_classify "$@" 2>/dev/null; }

# The four settled cases, restated against the pure function so a refactor of
# proc_is_my_process cannot quietly change what any of them mean.
[[ "$(_c 0 0 "" "$NEEDLE" 0)" == "gone" ]] \
    && assert_pass "[SPEC-3] no /proc entry -> gone" \
    || assert_fail "[SPEC-3] no /proc entry -> gone" "got: $(_c 0 0 "" "$NEEDLE" 0)"

[[ "$(_c 1 1 "" "$NEEDLE" 1)" == "zombie" ]] \
    && assert_pass "[SPEC-3] readable but empty cmdline -> zombie" \
    || assert_fail "[SPEC-3] readable but empty cmdline -> zombie" "got: $(_c 1 1 "" "$NEEDLE" 1)"

[[ "$(_c 1 1 "/usr/bin/other --serve" "$NEEDLE" 1)" == "stranger" ]] \
    && assert_pass "[SPEC-3] someone else's cmdline -> stranger" \
    || assert_fail "[SPEC-3] someone else's cmdline -> stranger" "got: $(_c 1 1 "/usr/bin/other" "$NEEDLE" 1)"

[[ "$(_c 1 1 "/bin/bash $NEEDLE --model x" "$NEEDLE" 1)" == "ours" ]] \
    && assert_pass "[SPEC-3] our needle in the cmdline -> ours" \
    || assert_fail "[SPEC-3] our needle in the cmdline -> ours" "got: $(_c 1 1 "/bin/bash $NEEDLE" "$NEEDLE" 1)"

# ── The case this issue exists for ──────────────────────────────────────────
# The entry was there, the read failed, and by the re-check the entry was GONE.
# That is a process which exited between two syscalls — precisely the outcome
# the assertion wants — and it was being counted as a leak. It is the only new
# behaviour here, and it cannot produce a false negative: a process that is
# still running does not have its /proc entry disappear.
[[ "$(_c 1 0 "" "$NEEDLE" 0)" == "gone" ]] \
    && assert_pass "[SPEC-3] entry vanished between read and re-check -> gone, not a leak" \
    || assert_fail "[SPEC-3] entry vanished between read and re-check -> gone, not a leak" \
        "got: $(_c 1 0 "" "$NEEDLE" 0) — a process that has exited is being counted as leftover"
if _c 1 0 "" "$NEEDLE" 0 >/dev/null && proc_classify 1 0 "" "$NEEDLE" 0 >/dev/null 2>&1; then
    assert_fail "[SPEC-3] a vanished process must NOT be counted" "exit 0 means 'count it'"
else
    assert_pass "[SPEC-3] a vanished process is not counted"
fi

# Still fails CLOSED when the entry is genuinely still there. This is the row
# that must NOT change: an unreadable cmdline under a live entry is not
# evidence of absence, and a detector that skips what it cannot read has
# stopped detecting.
[[ "$(_c 1 0 "" "$NEEDLE" 1)" == "unprovable" ]] \
    && assert_pass "[SPEC-3] unreadable under a LIVE entry -> unprovable" \
    || assert_fail "[SPEC-3] unreadable under a LIVE entry -> unprovable" "got: $(_c 1 0 "" "$NEEDLE" 1)"
if proc_classify 1 0 "" "$NEEDLE" 1 >/dev/null 2>&1; then
    assert_pass "[SPEC-3] an unprovable entry IS counted (fails closed)"
else
    assert_fail "[SPEC-3] an unprovable entry IS counted (fails closed)" \
        "the detector stopped detecting"
fi

print_test_section "[SPEC-4] a counted process arrives with its reason attached"
# Two of the three previous fixes were guesses because the failure output was a
# bare count. `proc_reason` is what the caller prints beside each pid, so the
# next occurrence carries its own diagnosis instead of needing another CI run.
_mk 9008 __NOCMD__
if proc_is_my_process 9008 "$NEEDLE"; then
    if [[ -n "${PROC_IDENTITY_REASON:-}" ]]; then
        assert_pass "[SPEC-4] the classification is reported, not just the verdict"
    else
        assert_fail "[SPEC-4] the classification is reported, not just the verdict" \
            "counted the pid but said nothing about why"
    fi
else
    assert_fail "[SPEC-4] setup: 9008 should still be counted" "classification changed"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
