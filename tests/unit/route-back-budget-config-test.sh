#!/usr/bin/env bash
# [S4] Integration-style unit (#1217, ADR-045): the global route_back budget
# defaults to 2 (= exactly one jump back) and is overridable via
# ZBUILD_ROUTE_BACK_BUDGET. The per-edge `max` is a SUBORDINATE local cap; the
# global total is the hard ceiling. build_review_cycle ALWAYS returns rc=11 so
# the number of cycle.route_back events == the number of permitted jumps.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back budget default 2 + config override (#1217)"
setup_test_env "route-back-budget-config"

# _drive <budget|""> <edge_max|"">  → echoes the number of cycle.route_back events
_drive() {
    local _budget="$1" _edgemax="$2"
    local _tmp; _tmp="$(mktemp -d "$TEST_TEMP_DIR/rb-XXXXXX")"
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
        [[ -n "$_budget" ]] && export ZBUILD_ROUTE_BACK_BUDGET="$_budget"
        # Per-edge cap for build_review_cycle (standard.yaml declares none, so
        # this export survives load_template and exercises the subordinate cap).
        [[ -n "$_edgemax" ]] && export _TPL_CYCLE_ROUTE_BACK_MAX_build_review_cycle="$_edgemax"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null
        cycle_dispatch_stage() { _CYCLE_DISPATCH_VERDICT="pass"; return 0; }
        cycle_orchestrator_run() {
            _CYCLE_LAST_ITERATIONS=1
            if [[ "$1" == "design_impact_cycle" ]]; then
                _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
            fi
            _CYCLE_LAST_TERMINATED_REASON="route_back"
            _CYCLE_ROUTE_BACK_TO="plan"
            _CYCLE_ROUTE_BACK_FALLBACK_RC=8
            return 11
        }
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/review"; }
        runner_read_stage_verdict() { echo "request_changes"; }
        plugin_hook_call() { return 0; }
        main --issue 999 --template standard >/dev/null 2>&1
    )
    local _n; _n="$(grep -c '"type":"cycle.route_back"' "$_tmp/events/events.jsonl" 2>/dev/null || true)"
    [[ -z "$_n" ]] && _n=0
    printf '%s' "$_n"
}

# Default (unset): budget 2 → exactly one jump.
assert_eq "S4: default budget (unset) → 1 route_back (=2 total passes)" "1" "$(_drive "" "")"
# Override to 1 → zero jumps (no rewind at all).
assert_eq "S4: ZBUILD_ROUTE_BACK_BUDGET=1 → 0 route_backs" "0" "$(_drive 1 "")"
# Override to 3 → two jumps.
assert_eq "S4: ZBUILD_ROUTE_BACK_BUDGET=3 → 2 route_backs" "2" "$(_drive 3 "")"
# Per-edge cap subordinate: budget 5 but edge max 1 → edge cap wins (1 jump).
assert_eq "S4: budget=5 + per-edge max=1 → edge cap wins (1 route_back)" "1" "$(_drive 5 1)"
# Global is the hard ceiling: budget 2 but edge max 5 → global wins (1 jump).
assert_eq "S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)" "1" "$(_drive 2 5)"

print_test_results
