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
    _st="$(ps -o state= -p "$p" 2>/dev/null | tr -d ' ')"
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

# And the 500ms window must survive — widening it past 1s would retire the
# pre-#905 backstop regression this test exists to catch.
if /usr/bin/grep -q '500000000' "$_RFA"; then
    assert_pass "[SPEC-3] the 500ms reap window is unchanged"
else
    assert_fail "[SPEC-3] the 500ms window changed" \
        "widening past 1s blinds the pre-#905 backstop check"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
