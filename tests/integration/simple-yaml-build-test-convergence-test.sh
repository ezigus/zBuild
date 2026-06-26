#!/usr/bin/env bash
# Integration test: simple.yaml build_test_cycle exit_when predicate convergence (I10-B #1089)
#
# Verifies that raising max_iterations to 5 makes the exit_when predicate
# (objective-gate.verdict == pass) load-bearing for cycle termination.
#
# SPEC-1: _zbuild_read_objective_gate_verdict returns "pass" for a passing artifact
# SPEC-2: _zbuild_read_objective_gate_verdict returns "missing" when artifact absent
# SPEC-3: cycle converges at iter 2 (objective-gate: fail iter 1, pass iter 2)
# SPEC-4: build_test_cycle.exit_when.suite_green is a registered event type
# (SPEC-5 is in tests/unit/template-simple-yaml-test.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "simple.yaml build_test_cycle: exit_when convergence (I10-B #1089)"
setup_test_env "simple-yaml-build-test-convergence"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_RUN_ID="convergence-$$"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"

mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

ARTIFACTS_DIR="$ZBUILD_STATE_DIR/artifacts"

# ─── SPEC-1: _zbuild_read_objective_gate_verdict returns "pass" ─────────────
print_test_section "SPEC-1: _zbuild_read_objective_gate_verdict (pass artifact)"

printf '{"schema_version":1,"verdict":"pass","summary":"all green"}' \
    > "$ARTIFACTS_DIR/objective-gate-result.json"

set +e
_spec1_verdict="$(_zbuild_read_objective_gate_verdict "$ZBUILD_STATE_DIR")"
set -e

assert_eq "[SPEC-1] _zbuild_read_objective_gate_verdict returns pass for passing artifact" \
    "pass" "${_spec1_verdict:-}"

# ─── SPEC-2: _zbuild_read_objective_gate_verdict returns "missing" ───────────
print_test_section "SPEC-2: _zbuild_read_objective_gate_verdict (absent artifact)"

rm -f "$ARTIFACTS_DIR/objective-gate-result.json"

set +e
_spec2_verdict="$(_zbuild_read_objective_gate_verdict "$ZBUILD_STATE_DIR")"
set -e

assert_eq "[SPEC-2] _zbuild_read_objective_gate_verdict returns missing when artifact absent" \
    "missing" "${_spec2_verdict:-}"

# ─── SPEC-3: fail→pass convergence at iter 2 ────────────────────────────────
# Stub cycle_dispatch_stage: objective-gate returns fail on iter 1, pass on
# iter 2. Build and test always return pass. The cycle must converge at iter 2
# via the exit_when predicate (not by hitting max_iterations=5).
print_test_section "SPEC-3: fail→pass convergence at iter 2 (exit_when predicate)"

# shellcheck disable=SC2317
cycle_dispatch_stage() {
    local _st_stage="$1" _st_iter="$2" _st_state_file="$3"
    local _st_state_dir; _st_state_dir="$(dirname "$_st_state_file")"
    local _st_art="$_st_state_dir/artifacts"; mkdir -p "$_st_art"

    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""

    case "$_st_stage" in
        build)
            printf '{"schema_version":1,"verdict":"pass","iterations":1}' \
                > "$_st_art/build-summary.json"
            ;;
        test)
            printf '{"schema_version":1,"verdict":"pass","exit_code":0}' \
                > "$_st_art/test-results.json"
            ;;
        objective-gate)
            if [[ "$_st_iter" -le 1 ]]; then
                printf '{"schema_version":1,"verdict":"fail","summary":"tests failed"}' \
                    > "$_st_art/objective-gate-result.json"
                _CYCLE_DISPATCH_VERDICT_RAW="fail"
                _CYCLE_DISPATCH_VERDICT="fail"
            else
                printf '{"schema_version":1,"verdict":"pass","summary":"all green"}' \
                    > "$_st_art/objective-gate-result.json"
                _CYCLE_DISPATCH_VERDICT_RAW="pass"
                _CYCLE_DISPATCH_VERDICT="pass"
                # Call the I10-B helper and emit the suite-green event.
                local _g_v; _g_v="$(_zbuild_read_objective_gate_verdict "$_st_state_dir")"
                if [[ "$_g_v" == "pass" ]]; then
                    eb_emit_event "build_test_cycle.exit_when.suite_green" \
                        "iter=$_st_iter" "verdict=pass" 2>/dev/null || true
                fi
            fi
            ;;
        *)
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
    esac
    return 0
}

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
_ORC_RC=$?
set -e

assert_eq "[SPEC-3] cycle converged (rc=0, not max_iterations)" "0" "$_ORC_RC"
assert_eq "[SPEC-3] terminated reason is converged (not max_iterations)" \
    "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-3] cycle ran exactly 2 iterations (fail then pass)" \
    "2" "${_CYCLE_LAST_ITERATIONS:-}"

# ─── SPEC-4: build_test_cycle.exit_when.suite_green is a registered event ────
print_test_section "SPEC-4: build_test_cycle.exit_when.suite_green in event-schema.json"

if grep -q '"build_test_cycle.exit_when.suite_green"' "$REPO_ROOT/config/event-schema.json"; then
    assert_pass "[SPEC-4] build_test_cycle.exit_when.suite_green registered in event-schema.json"
else
    assert_fail "[SPEC-4] build_test_cycle.exit_when.suite_green registered in event-schema.json" \
        "event type missing from config/event-schema.json"
fi

# ─── No-LLM guard: events.jsonl must not contain model.route events ──────────
# The exit_when predicate must use only the objective-gate artifact, never LLM.
if grep -q '"model\.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "no model.route events in events.jsonl — exit_when uses artifact only" \
        "LLM was consulted; LLM must not gate convergence"
else
    assert_pass "no model.route events in events.jsonl — exit_when uses artifact only"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
