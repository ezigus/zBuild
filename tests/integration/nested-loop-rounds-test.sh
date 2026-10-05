#!/usr/bin/env bash
# tests/integration/nested-loop-rounds-test.sh — the outer loop goes round when
# an inner loop ends without converging (#2271, ADR-068).
#
# Why: the default flow becomes one outer loop holding the design loop and the
# build loop (Eric, 2026-10-04). An inner loop that uses up its rounds must not
# halt the run while the outer loop has rounds left, and must not let the outer
# round carry on into later members as if nothing happened: build must not run
# on a design its checks still reject. The outer round ends there, the outer
# loop goes round from the top, and each inner loop starts again with a fresh
# counter. When the outer rounds are spent, the run stops.
#
# L1 [guard]  everything passes: one outer round, every member runs once
# L2 [change] the design loop runs out of rounds: build is skipped, the outer
#             loop goes round and design starts again at round 1; when the
#             outer rounds are spent, the outer loop does not report success
# L4 [change] design fails in outer round 1 only: round 2 starts design with a
#             fresh counter, and the outer loop then converges
# L5 [change] an outer exit_when with several conditions is read correctly
#             after an inner loop with a single condition has run inside it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the outer loop goes round when an inner loop ends unconverged (#2271)"
setup_test_env "nested-loop-rounds"

# shellcheck source=../lib/nested-loop-rounds-fixture.sh
source "$REPO_ROOT/tests/lib/nested-loop-rounds-fixture.sh"

print_test_section "L1/L5: everything passes"
DESIGN_GATE=pass TEST=pass _run; rc=$?
assert_eq "[L1] the outer loop converges" "0" "$rc"
assert_eq "[L1] design runs once" "1" "$(_count design 1)"
assert_eq "[L1] impact runs once" "1" "$(_count impact 1)"
assert_eq "[L5] the outer loop needs only one round" "1" "$(grep -c '^impact|' "$LOG" || true)"

print_test_section "L2: the design loop runs out of rounds"
DESIGN_GATE=fail TEST=pass _run; rc=$?
assert_eq "[L2] design starts again at round 1 in the second outer round" "2" "$(_count design 1)"
assert_eq "[L2] build never runs on a design the checks reject" "0" "$(grep -c '^build|' "$LOG" || true)"
assert_eq "[L2] impact never runs either" "0" "$(grep -c '^impact|' "$LOG" || true)"
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[L2] the outer loop does not report success (rc=$rc)"
else
    assert_fail "[L2] the outer loop does not report success" "rc=0"
fi

print_test_section "L4: design fails in the first outer round only"
DESIGN_GATE=fail-first-round TEST=pass _run; rc=$?
assert_eq "[L4] the outer loop converges in round 2" "0" "$rc"
assert_eq "[L4] design started at round 1 in both outer rounds" "2" "$(_count design 1)"
assert_eq "[L4] build ran once, in round 2" "1" "$(_count build 1)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
