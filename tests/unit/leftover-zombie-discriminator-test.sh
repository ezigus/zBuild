#!/usr/bin/env bash
# Tests: the leftover-process discriminator used by route-fast-abort (#1942).
#
# The predicate under test is small and lives inline in an INTEGRATION test that
# takes ~30s and needs a router driver. Exercised here directly so the rule —
# "a zombie is not a leftover, a live process is" — has a fast, deterministic
# home and can be ablated in isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "leftover-process discriminator (#1942)"
setup_test_env "zb-zombie-discriminator"

# The predicate, lifted verbatim from route-fast-abort-test.sh. Kept as a copy
# ON PURPOSE and asserted against the real file below, so this test cannot
# silently drift from the code it describes.
_counts_as_leftover() {
    local p="$1" _st
    kill -0 "$p" 2>/dev/null || return 1
    # `|| _st="Z"` is NOT cosmetic. Under `set -euo pipefail`, if the process
    # exits between the `kill -0` above and this `ps`, the pipeline returns
    # non-zero, the assignment fails, and set -e kills the whole FILE —
    # silently, because stderr is redirected. Absorbing it routes a
    # now-dead process through the Z branch, which is what it is.
    _st="$(ps -o state= -p "$p" 2>/dev/null | tr -d ' ')" || _st="Z"
    case "$_st" in
        Z*) return 1 ;;
        *)  return 0 ;;
    esac
}

# ─── [SPEC-1][change] a zombie is NOT a leftover ────────────────────────────
# The defect: `kill -0` succeeds for a process that has exited but not been
# reaped, so the abort test counted corpses as escapees. ubuntu-only, because
# PID 1 reaps promptly on macOS and not reliably in a CI container.
print_test_section "[SPEC-1][change] an unreaped corpse is not a leftover"

# A real zombie needs a parent that outlives its child and never waits. bash
# auto-reaps background jobs, so perl's fork is the reliable way to make one.
_Z_INFO="$TEST_TEMP_DIR/zombie.txt"
perl -e '
    my $pid = fork();
    if ($pid == 0) { exit 0 }
    open(my $fh, ">", $ARGV[0]); print $fh "$pid\n"; close($fh);
    select(undef,undef,undef,3);
' "$_Z_INFO" &
_Z_PARENT=$!
_w=0
while [[ ! -s "$_Z_INFO" && $_w -lt 100 ]]; do sleep 0.05; _w=$((_w+1)); done
sleep 0.3
_ZPID="$(tr -d '[:space:]' < "$_Z_INFO" 2>/dev/null || true)"

# Premise, asserted rather than assumed — if this is not a zombie the SPEC below
# proves nothing, and a silently-reaped child would make it pass vacuously.
_ZSTATE="$(ps -o state= -p "$_ZPID" 2>/dev/null | tr -d ' ')"
assert_contains "[SPEC-1] premise: a real zombie was created" "${_ZSTATE:-none}" "Z"
if kill -0 "$_ZPID" 2>/dev/null; then
    assert_pass "[SPEC-1] premise: kill -0 SUCCEEDS for it (this is the trap)"
else
    assert_fail "[SPEC-1] premise: kill -0 should succeed for a zombie" "it did not"
fi

if _counts_as_leftover "$_ZPID"; then
    assert_fail "[SPEC-1] a zombie must NOT count as a leftover" "counted"
else
    assert_pass "[SPEC-1] a zombie does not count as a leftover"
fi

kill "$_Z_PARENT" 2>/dev/null || true
wait "$_Z_PARENT" 2>/dev/null || true

# ─── [SPEC-2][guard] a LIVE process still counts ────────────────────────────
# Without this the fix could be "count nothing", which would pass SPEC-1 and
# silently retire the leak detection the abort test exists for.
print_test_section "[SPEC-2][guard] a genuinely running process still counts"

sleep 30 &
_LIVE=$!
sleep 0.2
if _counts_as_leftover "$_LIVE"; then
    assert_pass "[SPEC-2] a live process IS a leftover"
else
    assert_fail "[SPEC-2] a live process must count as a leftover" "not counted"
fi
kill "$_LIVE" 2>/dev/null || true
wait "$_LIVE" 2>/dev/null || true

# A PID that does not exist at all is not a leftover either.
if _counts_as_leftover 999999; then
    assert_fail "[SPEC-2] a nonexistent PID must not count" "counted"
else
    assert_pass "[SPEC-2] a nonexistent PID does not count"
fi

# ─── [SPEC-3][guard] this test cannot drift from the real one ──────────────
# The predicate above is a copy. Assert the integration test actually contains
# the discriminator, so deleting it there cannot leave this file green.
print_test_section "[SPEC-3][guard] the integration test carries the discriminator"

_RFA="$REPO_ROOT/tests/integration/route-fast-abort-test.sh"
assert_file_exists "[SPEC-3] route-fast-abort-test.sh exists" "$_RFA"
if /usr/bin/grep -q 'ps -o state=' "$_RFA" && /usr/bin/grep -q 'Z\*)' "$_RFA"; then
    assert_pass "[SPEC-3] it discriminates on process state, not just kill -0"
else
    assert_fail "[SPEC-3] the discriminator is missing from the real test" \
        "route-fast-abort-test.sh counts zombies again"
fi

# #1975: the pre-#905 backstop check no longer rides on the reap window.
#
# It used to: a window under 1s was the only thing separating a synchronous
# abort from the disowned `{ sleep 1 && kill -KILL; } &` shape, so widening it
# blinded that check. But the window is also the leak detector, and as a leak
# detector it is load-sensitive — how fast PID 1 reaps is its scheduling
# decision, and on a loaded ubuntu runner it is not reliably inside 500ms. One
# assertion carrying both jobs could satisfy neither.
#
# The discriminator moved to an elapsed_ms LOWER bound, which is load-monotone:
# the handler cannot return before its own 1s watchdog fires, and load can only
# push wall-clock up. Guard THAT now — the window is free to be generous,
# because a genuine leak is a live 60s stub that outlives any window.
if /usr/bin/grep -q 'elapsed_ms -ge 800' "$_RFA"; then
    assert_pass "[SPEC-3] the synchronous-abort lower bound is present"
else
    assert_fail "[SPEC-3] the synchronous-abort lower bound is missing" \
        "without it nothing separates a synchronous abort from the pre-#905 disowned backstop"
fi

# ─── [SPEC-4][guard] the reap window is generous ───────────────────────────
# #2029. The note above already concluded this — "the window is free to be
# generous, because a genuine leak is a live 60s stub that outlives any window"
# — and then left the window at 2s anyway. It kept failing: ubuntu CI red on
# PR #2028, on a diff that cannot reach this code, with both timing assertions
# green and the stub gone microseconds after the deadline expired.
#
# A stub that is still shutting down when a fixed wall-clock bound expires is
# not a leak. The leak this detects is a 60s sleep that ignored its signal, and
# no plausible amount of load makes that finish inside 15s. Widening costs a
# few seconds on the rare failing run and nothing at all on a passing one.
#
# The bound is asserted here rather than left to a comment because this is the
# third time this window has been tuned (#1943, #1975, now) and each previous
# value looked equally reasonable when it was written.
# Read the window in SECONDS from its single named definition, rather than
# scraping nanoseconds out of the deadline expression.
#
# The first version of this check grepped the deadline for a numeric literal. It
# broke the moment the window was given a name (#2029) — a guard that recognises
# only the shape it was written against, which is the failure this whole family of
# tests keeps producing. `|| true` because a no-match must reach the assertion
# below and be reported, not kill the file under `set -e`.
_win_s="$(/usr/bin/grep -oE '^reap_window_s=[0-9]+' "$_RFA" | head -1 | cut -d= -f2 || true)"
_win=""
[[ -n "$_win_s" ]] && _win=$(( _win_s * 1000000000 ))
if [[ -n "$_win" && "$_win" -ge 10000000000 ]]; then
    assert_pass "[SPEC-4] the reap window is at least 10s (got ${_win}ns)"
else
    assert_fail "[SPEC-4] the reap window is at least 10s" \
        "reap_window_s='${_win_s:-<not found>}' — a shutting-down stub will be counted as a leak under load"
fi

# ─── [SPEC-5][guard] a non-zero count is always explained ──────────────────
# The diagnostic exists so a failure arrives with its own diagnosis instead of
# needing another CI run. On PR #2028 it printed its header —
#
#   DIAGNOSTIC: 1 leftover stub(s) after the 2s reap window:
#
# — and then NOTHING, because it describes a pid only while
# `_rfa_is_my_stub` still says the pid is ours, and by diagnosis time the stub
# had exited. So the one run where the diagnostic was most needed produced a
# bare count, which is the exact thing it was built to stop.
#
# "Counted during the poll, gone by the time we looked" is the single most
# useful line that could have appeared there, and it was the one the guard
# suppressed. Describe every pid; let the classification say what it is.
# Comment lines are stripped first: the fix's own comment quotes the old code
# as the thing it replaced, and a guard that matches its own documentation
# reports the defect forever. (Same trap as T8 in the impact-prompt guard.)
if /usr/bin/grep -vE '^[[:space:]]*#' "$_RFA" \
    | /usr/bin/grep -qE '_rfa_is_my_stub "\$p" && _rfa_describe'; then
    assert_fail "[SPEC-5] the diagnostic explains every pid it counted" \
        "it still describes only pids still classified as ours — a stub that exited leaves a bare count"
else
    assert_pass "[SPEC-5] the diagnostic explains every pid it counted"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
