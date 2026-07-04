#!/usr/bin/env bash
# #1217 review fix (SHOULD-FIX): a false-fail after a successful correction.
#
# When an EARLIER cycle terminates unconverged (rc=2 → sets the sticky
# _RUNNER_CYCLE_UNCONVERGED* group) and a LATER cycle then route_backs to a
# point AT/BEFORE it, the earlier cycle REPLAYS and CONVERGES. Without resetting
# the sticky flag, final-status wrongly reports failed despite the successful
# correction. This drives the real runner over standard.yaml with a stubbed
# cycle_orchestrator_run and asserts the pipeline completes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back clears stale unconverged after correction (#1217)"
setup_test_env "route-back-unconverged-reset"

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
    export _DIC_CALLS="$_tmp/dic-calls"
    export _BRC_CALLS="$_tmp/brc-calls"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

    # design_impact_cycle: unconverged (rc=2) on the FIRST pass (sets the sticky
    # flag), then converges (rc=0) on the replay. build_review_cycle: routes
    # back to design_impact_cycle (an EARLIER unit) once, then converges.
    cycle_orchestrator_run() {
        _CYCLE_LAST_ITERATIONS=1
        if [[ "$1" == "design_impact_cycle" ]]; then
            local n=0; [[ -f "$_DIC_CALLS" ]] && n="$(cat "$_DIC_CALLS")"
            n=$((n + 1)); echo "$n" > "$_DIC_CALLS"
            if [[ $n -eq 1 ]]; then
                _CYCLE_LAST_TERMINATED_REASON="max_iterations"; return 2
            fi
            _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
        fi
        local m=0; [[ -f "$_BRC_CALLS" ]] && m="$(cat "$_BRC_CALLS")"
        m=$((m + 1)); echo "$m" > "$_BRC_CALLS"
        if [[ $m -eq 1 ]]; then
            _CYCLE_LAST_TERMINATED_REASON="route_back"
            _CYCLE_ROUTE_BACK_TO="design_impact_cycle"
            _CYCLE_ROUTE_BACK_FALLBACK_RC=2
            return 11
        fi
        _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
    }
    _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/review"; }
    runner_read_stage_verdict() { echo "approve"; }
    plugin_hook_call() {
        local state="$4"; local artdir; artdir="$(dirname "$state")/artifacts"; mkdir -p "$artdir"
        printf '{"verdict":"approve"}' > "$artdir/review.json"
        return 0
    }

    main --issue 999 --template standard >/dev/null 2>&1
)

_state="$_tmp/state/pipeline-state.json"
_ev="$_tmp/events/events.jsonl"

# The route_back fired exactly once (the correction happened).
_rb_count="$(grep -c '"type":"cycle.route_back"' "$_ev" 2>/dev/null || true)"
[[ -z "$_rb_count" ]] && _rb_count=0
assert_eq "reset: cycle.route_back emitted once (correction jump)" "1" "$_rb_count"

# design_impact_cycle ran twice (initial unconverged + replay converged).
_dic="$(cat "$_tmp/dic-calls" 2>/dev/null || echo 0)"
assert_eq "reset: design_impact_cycle ran twice (unconverged → replay)" "2" "$_dic"

# The stale unconverged flag was cleared → pipeline completes (NOT failed).
_status="$(jq -r '.status' "$_state" 2>/dev/null)"
assert_eq "reset: pipeline completes after correction (no false-fail)" "complete" "$_status"

print_test_results
