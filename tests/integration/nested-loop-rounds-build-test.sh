#!/usr/bin/env bash
# tests/integration/nested-loop-rounds-build-test.sh — the outer loop goes round
# when the build loop ends without converging (#2271, ADR-068). Split from
# nested-loop-rounds-test.sh (#2310), which holds L1, L2, L4 and L5.
#
# Why: the default flow becomes one outer loop holding the design loop and the
# build loop (Eric, 2026-10-04). An inner loop that uses up its rounds must not
# halt the run while the outer loop has rounds left, and must not let the outer
# round carry on into later members as if nothing happened: build must not run
# on a design its checks still reject. The outer round ends there, the outer
# loop goes round from the top, and each inner loop starts again with a fresh
# counter. When the outer rounds are spent, the run stops.
#
# L3 [change] the build loop runs out of rounds with tests failing: the run is
#             not halted at once — the outer loop goes round from design
# L6 [guard]  a build loop that is blocked (a structural failure) stops the run
#             — the outer loop does not go round to repeat it (written after
#             the fix, with the rate-limit case covered by
#             cycle-rate-limit-aborts-run-test.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the outer loop goes round when the build loop ends unconverged (#2271)"
setup_test_env "nested-loop-rounds-build"

# shellcheck source=../lib/nested-loop-rounds-fixture.sh
source "$REPO_ROOT/tests/lib/nested-loop-rounds-fixture.sh"

print_test_section "L3: the build loop runs out of rounds with tests failing"
DESIGN_GATE=pass TEST=fail _run; rc=$?
assert_eq "[L3] the outer loop goes round: design runs again" "2" "$(_count design 1)"
assert_eq "[L3] the build loop starts again at round 1" "2" "$(_count build 1)"
if [[ "$rc" -ne 0 ]]; then
    assert_pass "[L3] when the outer rounds are spent the run does not succeed (rc=$rc)"
else
    assert_fail "[L3] when the outer rounds are spent the run does not succeed" "rc=0"
fi

print_test_section "L6: a blocked build loop stops the run"
DESIGN_GATE=pass TEST=fail BUILD=blocked _run; rc=$?
assert_eq "[L6] the outer loop does not go round" "1" "$(_count design 1)"
assert_eq "[L6] the run stops as blocked (rc=5), not as a config error" "5" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
