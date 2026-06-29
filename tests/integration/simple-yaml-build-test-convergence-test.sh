#!/usr/bin/env bash
# Integration test: simple.yaml build_test_cycle convergence via gate-aggregator
# (B6 #1138, ADR-040 — amends ADR-013/ADR-021/ADR-019; executes ADR-037 §6).
#
# After the cutover, the build_test_cycle exit_when predicate is
# gate-aggregator.verdict == pass — the single merge-blocking convergence
# construct in the decomposed pipeline (ADR-040 §5). This replaces the retired
# monolithic gate convergence path.
#
# SPEC-1: simple.yaml's build_test_cycle exit_when is wired to gate-aggregator
# SPEC-2: the cycle roster is the decomposed gate set
# SPEC-3: cycle converges at iter 2 (gate-aggregator: fail iter 1, pass iter 2)
# SPEC-4: convergence is artifact-driven only — no model.route (LLM) events
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "simple.yaml build_test_cycle: gate-aggregator convergence (B6 #1138)"
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

# ─── SPEC-1: exit_when wired to gate-aggregator ──────────────────────────────
print_test_section "SPEC-1: build_test_cycle exit_when source is gate-aggregator"

assert_eq "[SPEC-1] exit_when stage is gate-aggregator" \
    "gate-aggregator" "${_TPL_CYCLE_UNTIL_STAGE_build_test_cycle:-}"
assert_eq "[SPEC-1] exit_when field is verdict" \
    "verdict" "${_TPL_CYCLE_UNTIL_FIELD_build_test_cycle:-}"
assert_eq "[SPEC-1] exit_when value is pass" \
    "pass" "${_TPL_CYCLE_UNTIL_VALUE_build_test_cycle:-}"

# ─── SPEC-2: decomposed gate roster ──────────────────────────────────────────
print_test_section "SPEC-2: cycle roster is the decomposed mechanical gate set"

# #1129 Change C (ADR-012): lint/coverage/mutation dropped as cycle members.
assert_eq "[SPEC-2] _TPL_CYCLE_STAGES_build_test_cycle" \
    "build,test,shape-floor,acceptance-gate,secret-scan,gate-aggregator" \
    "${_TPL_CYCLE_STAGES_build_test_cycle:-}"

# ─── SPEC-3: fail→pass convergence at iter 2 ─────────────────────────────────
# Stub cycle_dispatch_stage: gate-aggregator returns fail on iter 1, pass on
# iter 2. Build/test and every other gate always pass. The cycle must converge
# at iter 2 via the exit_when predicate (not by hitting max_iterations=5).
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
        gate-aggregator)
            if [[ "$_st_iter" -le 1 ]]; then
                printf '{"schema_version":1,"verdict":"fail","summary":"a gate failed"}' \
                    > "$_st_art/gate-aggregator-result.json"
                _CYCLE_DISPATCH_VERDICT_RAW="fail"
                _CYCLE_DISPATCH_VERDICT="fail"
            else
                printf '{"schema_version":1,"verdict":"pass","summary":"all gates pass"}' \
                    > "$_st_art/gate-aggregator-result.json"
                _CYCLE_DISPATCH_VERDICT_RAW="pass"
                _CYCLE_DISPATCH_VERDICT="pass"
            fi
            ;;
        *)
            # shape-floor, acceptance-gate, secret-scan all pass (defaults above);
            # only the aggregator drives convergence.
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

# ─── SPEC-4: convergence is artifact-driven only (no LLM) ─────────────────────
# The exit_when predicate keys on gate-aggregator (a T0 tool) and consumes only
# result artifacts, never an LLM call (ADR-037 §3). NB: the flow's gates are
# LLM-free, but acceptance-gate is kind:agent / T1 (it shells negctl+reachability
# mechanically, no model call) — so "no model.route" is the precise invariant,
# not "every gate is a T0 tool".
print_test_section "SPEC-4: no model.route events — convergence uses artifacts only"

if grep -q '"model\.route"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-4] no model.route events in events.jsonl — exit_when uses artifact only" \
        "LLM was consulted; LLM must not gate convergence"
else
    assert_pass "[SPEC-4] no model.route events in events.jsonl — exit_when uses artifact only"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
