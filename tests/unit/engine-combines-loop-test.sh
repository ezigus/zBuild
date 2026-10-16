#!/usr/bin/env bash
# tests/unit/engine-combines-loop-test.sh — the engine combines a loop's
# members by the template's rule; gate-aggregator is retired (#2368, ADR-040).
#
# Why: gate-aggregator was a stage whose only job was to combine the other
# members' outcomes into one — the engine's job. The template's exit_when names
# the members that must pass; a member with no outcome this round counts as
# failed, as gate-aggregator's fail-closed rule did.
#
#   L1 [change] after each round the loop writes <loop>-summary.md: every
#               member, its outcome and its one-line reason
#   L2 [guard]  a member with no outcome this round holds the loop
#   L3 [change] no shipped template has a gate-aggregator stage, and
#               build_test_cycle's exit_when names the members that must pass
#   L4 [change] no manifest declares `convergence:`; gate-aggregator is gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the engine combines a loop's members (#2368)"
setup_test_env "engine-combines-loop"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR/artifacts"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
SUMMARY="$ZBUILD_STATE_DIR/artifacts/build-test-cycle-summary.md"

# round 1: gate-a fails; round 2: gate-b writes no outcome; round 3: both pass.
cycle_dispatch_stage() {
    local stage="$1" iter="$2" v=pass r="checked it"
    [[ "$stage" == gate-a && "$iter" == 1 ]] && { v=fail; r="two problems found"; }
    if [[ "$stage" == gate-b && "$iter" == 2 ]]; then
        _CYCLE_DISPATCH_VERDICT=""; _CYCLE_DISPATCH_STATUS=""; _CYCLE_DISPATCH_REASON=""
        return 0
    fi
    _CYCLE_DISPATCH_VERDICT="$v"; _CYCLE_DISPATCH_REASON="$r"
    [[ "$v" == fail ]] && _CYCLE_DISPATCH_STATUS="failed" || _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

load_template "$REPO_ROOT/tests/fixtures/templates/cycle-multi-exit-when-all.yaml"
cycle_orchestrator_run "build-test-cycle" "$ZBUILD_STATE_DIR" "$STATE_FILE" >/dev/null 2>&1; rc=$?
H="$ZBUILD_STATE_DIR/cycle-build-test-cycle-history.jsonl"

print_test_section "L1: the loop's summary"
assert_file_exists "[L1] the loop writes its summary" "$SUMMARY"
_s="$(cat "$SUMMARY" 2>/dev/null)"
assert_contains "[L1] it names the loop and the round" "$_s" "build-test-cycle — round 3"
assert_contains "[L1] every member, its outcome and its reason" "$_s" "- gate-a: pass — checked it"
assert_contains "[L1] ...each of them" "$_s" "- gate-b: pass — checked it"

print_test_section "L2: a member with no outcome this round holds the loop"
assert_eq "[L2] the loop converges in round 3, not 2" "3" "$(wc -l < "$H" | tr -d ' ')"
assert_eq "[L2] ...and converges" "0" "$rc"

print_test_section "L3: the shipped templates"
for _t in "$REPO_ROOT"/config/templates/*.yaml; do
    if grep -qE '^[[:space:]]*-[[:space:]]*gate-aggregator[[:space:]]*$|^gate-aggregator:' "$_t"; then
        assert_fail "[L3] ${_t##*/} has no gate-aggregator stage" "found"
    else
        assert_pass "[L3] ${_t##*/} has no gate-aggregator stage"
    fi
done
_ew="$(awk '/^build_test_cycle:/{f=1} f&&/exit_when:/{e=1} e&&/max_iterations:/{exit} e' "$REPO_ROOT/config/templates/simple.yaml")"
for _m in test-author build test issue-acceptance; do
    assert_contains "[L3] simple: build_test_cycle must pass $_m" "$_ew" "stage: $_m,"
done

print_test_section "L4: no stage declares its own convergence"
_conv="$(grep -l '^convergence:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"
assert_eq "[L4] no manifest declares convergence:" "" "$_conv"
assert_eq "[L4] gate-aggregator is gone" "no" "$([[ -e "$REPO_ROOT/plugins/tool/gate-aggregator" ]] && echo yes || echo no)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
