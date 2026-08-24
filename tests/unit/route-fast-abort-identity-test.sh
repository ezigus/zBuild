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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
