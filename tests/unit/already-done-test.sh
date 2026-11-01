#!/usr/bin/env bash
# tests/unit/already-done-test.sh — every stage is told, as build is, to finish
# at once when its work is already done (#2445, ADR-067 §8).
#
# Why: on #1754 (run 41249802310) design and test-author each spent 10–15
# minutes a round re-proving work that was already done; build, told "if it is
# already done, say so at once", took 4 minutes. The same rule now reaches every
# stage from the engine, not from each stage's own text.
#
# A1 [change] the rules the engine gives every stage say: if what you are asked
#             to produce is already there and right, and no finding is open for
#             you, confirm it and finish — do not redo it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
print_test_header "every stage finishes at once when its work is already done (#2445)"
setup_test_env "already-done"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
for _st in design test-author issue-acceptance; do
    _rules="$(_stage_block_rules "$_st" "$S" "$REPO_ROOT/plugins/agent/$_st/manifest.yaml" 2>/dev/null)"
    assert_contains "[A1] $_st is told what to do when its work is already there" "$_rules" "already there and right"
    assert_contains "[A1] ...to confirm it and finish, not redo it" "$_rules" "confirm it and finish"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
