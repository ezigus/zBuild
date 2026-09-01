#!/usr/bin/env bash
# [S2] Integration (#1217, ADR-045): once the global route_back budget is spent
# the runner does NOT rewind — it restores the stashed fallback rc and falls
# through to the normal by-severity terminal handling. Here build_test_cycle
# ALWAYS returns rc=11 with fallback rc=8; with the default budget (2 total
# passes = exactly one jump back) exactly ONE rewind fires, then the second
# rc=11 falls through to the rc=8 halt (status=failed). `plan` therefore
# dispatches TWICE and cycle.route_back fires exactly once.
# #979: repointed from the retired standard.yaml to simple.yaml
# (design_verify_cycle / build_test_cycle); the mechanic is template-agnostic.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back budget exhausted → by-severity terminal (#1217)"
setup_test_env "route-back-budget-exhausted"

# #1921 follow-up: the runner resolves repo_root from CWD, so an in-process
# `main` snapshots into whatever repository the test stands in. These files used
# REAL issue numbers from the working checkout, adding commits to real issues'
# state branches (measured: 3 per run onto issue-698). Reserved id + throwaway
# repo; the cd below is what actually contains it.
_ZB_ISSUE="$(zb_test_issue)"
_ZB_REPO="$(zb_test_repo rb-exhausted)"

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
    # shellcheck disable=SC1091
    cd "$_ZB_REPO" || exit 1
    source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

    cycle_orchestrator_run() {
        _CYCLE_LAST_ITERATIONS=1
        if [[ "$1" == "design_verify_cycle" ]]; then
            _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
        fi
        # ALWAYS request a route_back with fallback rc=8 (member_terminal_failure).
        # The orchestrator stashes the ORIGINAL reason so the runner can restore
        # it on the exhausted path (#1227); mimic that here with a distinctive
        # tautology cause that must survive to the terminal event.
        _CYCLE_LAST_TERMINATED_REASON="route_back"
        _CYCLE_ROUTE_BACK_TO="plan"
        _CYCLE_ROUTE_BACK_FALLBACK_RC=8
        _CYCLE_ROUTE_BACK_FALLBACK_REASON="member_terminal_failure"
        return 11
    }
    _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/build"; }
    runner_read_stage_verdict() { echo "request_changes"; }
    plugin_hook_call() { return 0; }

    main --issue "$_ZB_ISSUE" --template simple >/dev/null 2>&1
)

_state="$_tmp/state/pipeline-state.json"
_ev="$_tmp/events/events.jsonl"

_rb_count="$(grep -c '"type":"cycle.route_back"' "$_ev" 2>/dev/null || true)"
[[ -z "$_rb_count" ]] && _rb_count=0
assert_eq "S2: cycle.route_back emitted exactly once (budget=2 → one jump)" "1" "$_rb_count"

_plan_count="$(grep '"type":"stage.start"' "$_ev" 2>/dev/null | grep -c '"stage":"plan"')"
[[ -z "$_plan_count" ]] && _plan_count=0
assert_eq "S2: plan dispatched TWICE then budget spent (no third)" "2" "$_plan_count"

_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "S2: budget spent → fallback rc=8 → status=failed" "failed" "$_status"

# #1227 fix 3: on budget exhaustion the terminal reason must be the ORIGINAL
# cause (stashed by the orchestrator + restored by the runner), NOT "route_back".
_complete_reason="$(grep '"type":"cycle.complete"' "$_ev" 2>/dev/null | tail -1 | jq -r '.data.reason // empty' 2>/dev/null)"
assert_eq "S2: cycle.complete restates the ORIGINAL cause, not route_back" \
    "member_terminal_failure" "$_complete_reason"
_end_reason="$(grep '"type":"pipeline.end"' "$_ev" 2>/dev/null | tail -1 | jq -r '.data.reason // empty' 2>/dev/null)"
assert_eq "S2: pipeline.end reason is the ORIGINAL cause, not route_back" \
    "member_terminal_failure" "$_end_reason"

print_test_results
