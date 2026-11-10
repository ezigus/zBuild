#!/usr/bin/env bash
# tests/unit/turn-limit-default-test.sh — when nothing sets a stage's turn
# limit, it has none (#2458, ADR-018).
#
# Why: the fallback was 25 turns, which silently capped every stage that names
# no limit (test-author, issue-acceptance), and which the ADR-029 G3 step read
# as build's limit when build had said "no limit" (#1805 run 41489923219).
#
# M1 [change] with no template, environment or manifest limit, the resolved
#             limit is 0 — no --max-turns — and the stage's rules say so
# M2 [change] a stated limit still applies: environment, then manifest
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
print_test_header "no turn limit unless one is set (#2458)"
setup_test_env "turn-limit-default"

unset ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_MAX_TURNS_OVERRIDE ZBUILD_PLUGIN_DIR
assert_eq "[M1] nothing set → no limit" "0" "$(ZBUILD_CURRENT_STAGE=nostage _route_resolve_max_turns 2>/dev/null)"
_r="$(_stage_block_rules nostage "$TEST_TEMP_DIR/state" "$TEST_TEMP_DIR/no-manifest.yaml" 2>/dev/null)"
assert_contains "[M1] ...and the stage is told it has no limit on turns" "$_r" "with no limit on turns"

assert_eq "[M2] the environment's limit applies" "12" \
    "$(ZBUILD_ROUTER_MAX_TURNS=12 ZBUILD_CURRENT_STAGE=nostage _route_resolve_max_turns 2>/dev/null)"
assert_eq "[M2] a plugin's own limit applies" "45" \
    "$(ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/design" ZBUILD_CURRENT_STAGE=nostage _route_resolve_max_turns 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
