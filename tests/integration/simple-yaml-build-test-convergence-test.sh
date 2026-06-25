#!/usr/bin/env bash
# Integration test: simple.yaml build_test_cycle converges on objective-gate pass (#976)
#
# Verifies that the build_test_cycle declared in config/templates/simple.yaml uses
# objective-gate.verdict==pass as its exit_when predicate (not test_assessment), and
# that the cycle-orchestrator converges correctly after one or two iterations depending
# on the objective-gate stub verdict.
#
# SPEC-16: template loads and build_test_cycle appears in _TPL_CYCLES with objective-gate
#          as the exit_when stage.
# SPEC-17: test_assessment does not appear in _TPL_STAGES or _TPL_CYCLES (retire guard).
# SPEC-18: cycle exits converged after one iteration when objective-gate returns pass.
# SPEC-19: cycle runs two iterations when objective-gate returns fail on iter 1, pass on iter 2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "simple.yaml: build_test_cycle converges on objective-gate pass (#976)"
setup_test_env "simple-yaml-build-test-convergence"

SIMPLE_TPL="$REPO_ROOT/config/templates/simple.yaml"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_RUN_ID="simple-btc-convergence-$$"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

mkdir -p "$ZBUILD_STATE_DIR/artifacts" "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

# ─── Source under test ───────────────────────────────────────────────────────

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

set +e
load_template "$SIMPLE_TPL"
_load_rc=$?
set -e

# ─── SPEC-16: build_test_cycle in _TPL_CYCLES with objective-gate exit_when ──
# CHANGE: simple.yaml previously had no cycles. After #976, build_test_cycle is
# declared as a top-level cycle section with exit_when pointing at objective-gate.
# At the pre-#976 baseline, _TPL_CYCLES is empty for simple.yaml, so
# _spec16_found==0 and the exit_when var is unset — both assertions fail at baseline.

assert_eq "[SPEC-16] simple.yaml loads without error" "0" "$_load_rc"

_spec16_found=0
for _cyc in "${_TPL_CYCLES[@]}"; do
    [[ "$_cyc" == "build_test_cycle" ]] && _spec16_found=1 && break
done
assert_eq "[SPEC-16] build_test_cycle appears in _TPL_CYCLES" "1" "$_spec16_found"
assert_eq "[SPEC-16] build_test_cycle exit_when stage is objective-gate" \
    "objective-gate" "${_TPL_CYCLE_UNTIL_STAGE_build_test_cycle:-}"

# ─── SPEC-17: test_assessment is not in _TPL_STAGES or _TPL_CYCLES ───────────
# GUARD: simple.yaml must never wire test_assessment — the retired LLM convergence
# driver (ADR-037 / #976). This is a guard; it passes at baseline and here.

_spec17_ta_stages=0
for _s in "${_TPL_STAGES[@]}"; do
    [[ "$_s" == "test_assessment" ]] && _spec17_ta_stages=1 && break
done
assert_eq "[SPEC-17] test_assessment is absent from _TPL_STAGES" "0" "$_spec17_ta_stages"

_spec17_ta_cycles=0
for _c in "${_TPL_CYCLES[@]}"; do
    [[ "$_c" == "test_assessment" ]] && _spec17_ta_cycles=1 && break
done
assert_eq "[SPEC-17] test_assessment is absent from _TPL_CYCLES" "0" "$_spec17_ta_cycles"

# ─── Cycle dispatch stub ─────────────────────────────────────────────────────
# Mode-driven: _CYCLE_DISPATCH_MODE controls the objective-gate verdict.
# build and test always return pass; objective-gate follows the mode.
_CYCLE_DISPATCH_MODE="always_pass"
_SPEC19_OG_CALLS=0

cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$_CYCLE_DISPATCH_MODE" in
        always_pass)
            _CYCLE_DISPATCH_VERDICT="pass"
            _CYCLE_DISPATCH_VERDICT_RAW="pass"
            ;;
        fail_then_pass)
            if [[ "$stage" == "objective-gate" ]]; then
                _SPEC19_OG_CALLS=$(( _SPEC19_OG_CALLS + 1 ))
                if [[ $_SPEC19_OG_CALLS -ge 2 ]]; then
                    _CYCLE_DISPATCH_VERDICT="pass"
                    _CYCLE_DISPATCH_VERDICT_RAW="pass"
                else
                    _CYCLE_DISPATCH_VERDICT="fail"
                    _CYCLE_DISPATCH_VERDICT_RAW="fail"
                fi
            else
                _CYCLE_DISPATCH_VERDICT="pass"
                _CYCLE_DISPATCH_VERDICT_RAW="pass"
            fi
            ;;
    esac
    return 0
}

# ─── SPEC-18: cycle exits converged after one iter when pass on first call ────
# CHANGE: at baseline simple.yaml has no cycle so cycle_orchestrator_run was
# never invoked for build_test_cycle — the reason/iterations globals were never
# set by it. This assertion fails at baseline (no cycle → no run).

_CYCLE_DISPATCH_MODE="always_pass"
set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
_RC18=$?
set -e

assert_eq "[SPEC-18] one-iter-pass: cycle rc=0 (converged)"   "0"         "$_RC18"
assert_eq "[SPEC-18] one-iter-pass: reason=converged"          "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-18] one-iter-pass: exactly 1 iteration"       "1"         "${_CYCLE_LAST_ITERATIONS:-}"

# ─── SPEC-19: cycle runs two iters when objective-gate fails then passes ──────
# CHANGE: same baseline failure as SPEC-18 — no cycle wired means the two-iter
# path was unreachable. After #976 the orchestrator runs until convergence.

# Reset state file for second orchestrator run.
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"
_CYCLE_DISPATCH_MODE="fail_then_pass"
_SPEC19_OG_CALLS=0

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
_RC19=$?
set -e

assert_eq "[SPEC-19] fail-then-pass: cycle rc=0 (converged)"   "0"         "$_RC19"
assert_eq "[SPEC-19] fail-then-pass: reason=converged"          "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-19] fail-then-pass: exactly 2 iterations"      "2"         "${_CYCLE_LAST_ITERATIONS:-}"

# ─── Results ─────────────────────────────────────────────────────────────────

cleanup_test_env
print_test_results
exit $((FAIL > 0))
