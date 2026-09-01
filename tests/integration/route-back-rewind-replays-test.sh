#!/usr/bin/env bash
# [S1] Integration (#1217, ADR-045): a matched route_back (rc=11 from a cycle)
# rewinds the runner's dispatch-unit index to the named EARLIER unit and
# replays forward. Drives the real runner over simple.yaml with a stubbed
# cycle_orchestrator_run; the build_test_cycle routes back to the earlier
# `plan` leaf once, then converges. `plan` must therefore dispatch TWICE
# (initial + one replay), a cycle.route_back event fires once, and the
# pipeline completes.
# #979: repointed from the retired standard.yaml (design_impact_cycle /
# build_review_cycle) to simple.yaml (design_verify_cycle / build_test_cycle);
# the route_back mechanic under test is template-agnostic.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back rewind + replay-forward (#1217 / ADR-045)"
setup_test_env "route-back-rewind-replays"

# #1921 follow-up: the runner resolves repo_root from CWD, so an in-process
# `main` snapshots into whatever repository the test stands in. These files used
# REAL issue numbers from the working checkout, adding commits to real issues'
# state branches (measured: 3 per run onto issue-698). Reserved id + throwaway
# repo; the cd below is what actually contains it.
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo rb-rewind)"

_tmp="$(mktemp -d "$TEST_TEMP_DIR/rb-XXXXXX")"
(
    set +e
    export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
    export ZBUILD_EVENTS_DIR="$_tmp/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
    export ZBUILD_STATE_DIR="$_tmp/state"; mkdir -p "$ZBUILD_STATE_DIR"
    export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
    export ZBUILD_CYCLES_ENABLED=1
    export ZBUILD_CONTRACT_VALIDATOR=warn
    export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
    export _RB_CALLS_FILE="$_tmp/brc-calls"
    # shellcheck disable=SC1091
    cd "$_ZB_REPO" || exit 1
    source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

    # Leaf dispatches are observed via stage.start events (main defines its own
    # cycle_dispatch_stage at runtime, so we stub the plugin hook it calls).
    # design_verify_cycle always converges. build_test_cycle routes back to
    # `plan` on its FIRST invocation (rc=11), then converges on the second.
    cycle_orchestrator_run() {
        _CYCLE_LAST_ITERATIONS=1
        if [[ "$1" == "design_verify_cycle" ]]; then
            _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
        fi
        local n=0; [[ -f "$_RB_CALLS_FILE" ]] && n="$(cat "$_RB_CALLS_FILE")"
        n=$((n + 1)); echo "$n" > "$_RB_CALLS_FILE"
        if [[ $n -eq 1 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="route_back"
            _CYCLE_ROUTE_BACK_TO="plan"
            _CYCLE_ROUTE_BACK_FALLBACK_RC=2
            return 11
        fi
        _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
    }
    _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
    runner_read_stage_verdict() { echo "approve"; }
    plugin_hook_call() { return 0; }

    main --issue "$_ZB_ISSUE" --template simple >/dev/null 2>&1
)

_state="$_tmp/state/pipeline-state.json"
_ev="$_tmp/events/events.jsonl"

_plan_count="$(grep '"type":"stage.start"' "$_ev" 2>/dev/null | grep -c '"stage":"plan"')"
[[ -z "$_plan_count" ]] && _plan_count=0
assert_eq "S1: plan leaf dispatched TWICE (initial + one replay)" "2" "$_plan_count"

_rb_count="$(grep -c '"type":"cycle.route_back"' "$_ev" 2>/dev/null || true)"
[[ -z "$_rb_count" ]] && _rb_count=0
assert_eq "S1: cycle.route_back emitted exactly once" "1" "$_rb_count"

_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S1: pipeline completes after the bounded rewind" "complete" "$_status"

print_test_results
