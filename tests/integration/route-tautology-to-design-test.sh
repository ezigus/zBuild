#!/usr/bin/env bash
# [S1/S2] Integration (#1219, ADR-045/ADR-046): the build_test_cycle route_back
# edge rewinds to the EARLIER design_verify_cycle when the gate-aggregator surfaces
# a design-rooted failure (verdict==route_design). NOTE (#1583): tautology is no
# longer design-rooted (it is build-fixable), so this exercises the RETAINED, now
# dormant route_back PLUMBING generically — the cycle is STUBBED to emit route_back
# directly; no real tautology drives it. This drives the REAL runner over the
# REAL simple.yaml (so the route_back target is resolved from the loaded template,
# proving the wiring), with a stubbed cycle_orchestrator_run that emits rc=11 with
# the template-declared target. `impact` is the top-level leaf BETWEEN
# design_verify_cycle and build_test_cycle, so a rewind replays it — it is the
# observable "the pipeline rewound to design" signal.
#
# S1: build_test_cycle routes back ONCE then converges → impact dispatched twice,
#     cycle.route_back once, pipeline completes.
# S2: build_test_cycle ALWAYS routes back (fallback rc=8) → the global budget
#     (default 2 = one jump) is spent after one rewind; the second rc=11 falls
#     through to the by-severity rc=8 terminal → pipeline fails CLEANLY (no
#     infinite ping-pong, no third design pass).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "route_back plumbing → design_verify_cycle (retained/dormant; #1219, #1583)"
setup_test_env "route-tautology-to-design"

# _drive <mode> <events_dir> <state_file>  (mode: once|always)
_drive() {
    local mode="$1" evd="$2" stf="$3" calls="$4"
    (
        set +e
        export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
        export ZBUILD_EVENTS_DIR="$evd"; mkdir -p "$ZBUILD_EVENTS_DIR"
        export ZBUILD_EVENTS_JSONL="$evd/events.jsonl"
        export ZBUILD_STATE_DIR="$(dirname "$stf")"; mkdir -p "$ZBUILD_STATE_DIR"
        export ZBUILD_STATE_FILE="$stf"
        export ZBUILD_CYCLES_ENABLED=1
        export ZBUILD_CONTRACT_VALIDATOR=warn
        export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
        export _RTD_MODE="$mode" _RTD_CALLS="$calls"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/core/pipeline/runner.sh" 2>/dev/null

        cycle_orchestrator_run() {
            _CYCLE_LAST_ITERATIONS=1
            if [[ "$1" == "design_verify_cycle" ]]; then
                _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
            fi
            if [[ "$1" == "build_test_cycle" ]]; then
                # Read the route_back target that simple.yaml declared — proves the
                # wiring resolves to the earlier design_verify_cycle unit. Empty →
                # the wiring is missing (converge, which fails the assertions).
                local to="${_TPL_CYCLE_ROUTE_BACK_TO_build_test_cycle:-}"
                if [[ -z "$to" ]]; then _CYCLE_LAST_TERMINATED_REASON="converged"; return 0; fi
                local n=0; [[ -f "$_RTD_CALLS" ]] && n="$(cat "$_RTD_CALLS")"
                n=$((n + 1)); echo "$n" > "$_RTD_CALLS"
                if [[ "$_RTD_MODE" == "always" || $n -eq 1 ]]; then
                    _CYCLE_LAST_TERMINATED_REASON="route_back"
                    _CYCLE_ROUTE_BACK_TO="$to"
                    _CYCLE_ROUTE_BACK_FALLBACK_RC=8
                    return 11
                fi
                _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
            fi
            _CYCLE_LAST_TERMINATED_REASON="converged"; return 0
        }
        # Leaves + the advisory parallel lens group are no-op successes; we only
        # observe the `impact` leaf's stage.start count and the route_back event.
        _find_plugin_for_stage() { echo "$REPO_ROOT/plugins/agent/impact"; }
        runner_read_stage_verdict() { echo "pass"; }
        plugin_hook_call() { return 0; }
        parallel_group_run() { return 0; }

        main --issue 999 --template simple >/dev/null 2>&1
    )
}

# ─── S1: routes back ONCE, then converges ────────────────────────────────────
_t1="$(mktemp -d "$TEST_TEMP_DIR/s1-XXXXXX")"
_drive once "$_t1/events" "$_t1/state/pipeline-state.json" "$_t1/calls"
_ev1="$_t1/events/events.jsonl"; _st1="$_t1/state/pipeline-state.json"

_impact1="$(grep '"type":"stage.start"' "$_ev1" 2>/dev/null | grep -c '"stage":"impact"')"
[[ -z "$_impact1" ]] && _impact1=0
assert_eq "S1: impact leaf dispatched TWICE (initial + one replay after rewind)" "2" "$_impact1"

_rb1="$(grep -c '"type":"cycle.route_back"' "$_ev1" 2>/dev/null || true)"
[[ -z "$_rb1" ]] && _rb1=0
assert_eq "S1: cycle.route_back emitted exactly once" "1" "$_rb1"

_status1="$(jq -r '.status' "$_st1" 2>/dev/null)"
assert_eq "S1: pipeline completes after the bounded rewind" "complete" "$_status1"

# ─── S2: always tautological → budget spent → clean hard-fail (no ping-pong) ──
_t2="$(mktemp -d "$TEST_TEMP_DIR/s2-XXXXXX")"
_drive always "$_t2/events" "$_t2/state/pipeline-state.json" "$_t2/calls"
_ev2="$_t2/events/events.jsonl"; _st2="$_t2/state/pipeline-state.json"

_rb2="$(grep -c '"type":"cycle.route_back"' "$_ev2" 2>/dev/null || true)"
[[ -z "$_rb2" ]] && _rb2=0
assert_eq "S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)" "1" "$_rb2"

_impact2="$(grep '"type":"stage.start"' "$_ev2" 2>/dev/null | grep -c '"stage":"impact"')"
[[ -z "$_impact2" ]] && _impact2=0
assert_eq "S2: impact dispatched TWICE then budget spent (no third design pass)" "2" "$_impact2"

_status2="$(jq -r '.status' "$_st2" 2>/dev/null)"
assert_eq "S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)" "failed" "$_status2"

cleanup_test_env
print_test_results
