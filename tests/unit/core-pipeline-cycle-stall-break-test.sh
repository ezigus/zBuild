#!/usr/bin/env bash
# Tests: simple.yaml build_test_cycle feedback edge + the no-progress stall-break
# (issue #1117). simple.yaml's build_test_cycle loops on failure but declared no
# feedback edge, so build re-ran each iter with the identical task and zero
# failure context → empty_diff → no convergence, burning all 5 iterations.
#
# SPEC-1: the feedback edge delivers failure detail — _cycle_apply_feedback writes
#         a non-empty <to_field>.txt in the next-iter feedback dir referencing the
#         failure (reuses build's existing prior_test_assessment input).
# SPEC-2: the simple.yaml edge parses + the producer (test:test_failures_summary)
#         resolves to a path that EXISTS in simple.yaml's flow (no required-edge
#         cycle.feedback.missing surprise — it is required:false regardless).
# SPEC-3: the stall-break fires — build verdict=empty_diff + objective-gate
#         verdict!=pass ⇒ cycle terminates reason=stalled within <=2 iterations
#         (NOT max_iterations=5), emitting cycle.stalled.
# SPEC-4: empty_diff + objective-gate verdict=pass ⇒ converged (no false stall).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle feedback edge + no-progress stall-break (#1117)"
setup_test_env "cycle-stall-break-1117"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── SPEC-2 (parse + producer resolution) ────────────────────────────────────
# Assert the simple.yaml feedback edge parsed into the expected FB record and the
# producer resolves to the test plugin's test-failures-summary.md (a producer that
# EXISTS in simple.yaml's flow — the test stage is a cycle member).
print_test_section "SPEC-2: feedback edge parses + producer resolves to a real artifact"

assert_eq "[SPEC-2] simple.yaml build_test_cycle feedback edge parsed" \
    "test:test_failures_summary|build:prior_test_assessment:false" \
    "${_TPL_CYCLE_FEEDBACK_build_test_cycle:-}"

_RESOLVE_DIR="$TEST_TEMP_DIR/resolve"
mkdir -p "$_RESOLVE_DIR"
set +e
_resolved_src="$(_cycle_resolve_from_path "$_RESOLVE_DIR" "test" "test_failures_summary")"
set -e
case "$_resolved_src" in
    */test-failures-summary.md)
        assert_pass "[SPEC-2] test:test_failures_summary resolves to test-failures-summary.md" ;;
    *)
        assert_fail "[SPEC-2] test:test_failures_summary resolves to test-failures-summary.md" \
            "got: $_resolved_src" ;;
esac

# ─── SPEC-1 (feedback delivery) ──────────────────────────────────────────────
print_test_section "SPEC-1: feedback edge writes non-empty prior_test_assessment.txt"

_CYCLE_TRAP_CYCLE_ID="build_test_cycle"
FB_STATE="$TEST_TEMP_DIR/fb-state"
mkdir -p "$FB_STATE/artifacts"
# The test stage's failure summary (the producer present in simple.yaml's flow).
cat > "$FB_STATE/artifacts/test-failures-summary.md" <<'TFS'
# Test failures (iter 1)
- tests/unit/example-test.sh: assert_eq "[SPEC-3] foo" expected=3 actual=2 FAILED
TFS

# Load the parsed edge into the orchestrator's feedback array (mirrors what
# _cycle_load_template does at cycle entry) and wire it for the next iter. The
# simple.yaml edge is a single newline-free record, so a one-element array.
_CYCLE_FEEDBACK=("${_TPL_CYCLE_FEEDBACK_build_test_cycle}")
set +e
_cycle_apply_feedback 2 "$FB_STATE"; _fb_rc=$?
set -e
assert_eq "[SPEC-1] _cycle_apply_feedback rc=0 (optional producer present)" "0" "$_fb_rc"

_FB_FILE="$FB_STATE/cycle-build_test_cycle/iter-2/feedback/prior_test_assessment.txt"
assert_file_exists "[SPEC-1] prior_test_assessment.txt written to next-iter feedback dir" "$_FB_FILE"
[[ -s "$_FB_FILE" ]] \
    && assert_pass "[SPEC-1] prior_test_assessment.txt is non-empty" \
    || assert_fail "[SPEC-1] prior_test_assessment.txt is non-empty" "file empty"
assert_contains "[SPEC-1] feedback references the failure detail" \
    "$(cat "$_FB_FILE")" "[SPEC-3] foo"

# ─── SPEC-3 / SPEC-4 (stall-break vs converge) ───────────────────────────────
# Drive the REAL cycle_orchestrator_run with a stubbed dispatch hook. build always
# emits empty_diff; objective-gate verdict is parameterized.
_OG_VERDICT="fail"
# shellcheck disable=SC2317
cycle_dispatch_stage() {
    local _st_stage="$1" _st_iter="$2" _st_state_file="$3"
    local _st_dir; _st_dir="$(dirname "$_st_state_file")"
    local _art="$_st_dir/artifacts"; mkdir -p "$_art"
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_VERDICT_RAW="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$_st_stage" in
        build)
            printf '{"schema_version":1,"verdict":"empty_diff","iterations":1,"terminated_reason":"done_sentinel","files_changed":[]}' \
                > "$_art/build-summary.json"
            _CYCLE_DISPATCH_VERDICT="empty_diff"
            _CYCLE_DISPATCH_VERDICT_RAW="empty_diff"
            ;;
        test)
            printf '{"schema_version":1,"verdict":"pass","exit_code":0,"passed":1,"failed":0}' \
                > "$_art/test-results.json"
            ;;
        objective-gate)
            printf '{"schema_version":1,"verdict":"%s","summary":"x"}' "$_OG_VERDICT" \
                > "$_art/objective-gate-result.json"
            _CYCLE_DISPATCH_VERDICT="$_OG_VERDICT"
            _CYCLE_DISPATCH_VERDICT_RAW="$_OG_VERDICT"
            ;;
    esac
    return 0
}

_run_cycle() {
    local _label="$1"
    local _sd="$TEST_TEMP_DIR/run-$_label/state"
    mkdir -p "$_sd/artifacts"
    printf '{"schema_version":1,"status":"in_progress"}' > "$_sd/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    set +e
    cycle_orchestrator_run "build_test_cycle" "$_sd" "$_sd/pipeline-state.json"
    _RUN_RC=$?
    set -e
}

print_test_section "SPEC-3: empty_diff + gate!=pass ⇒ stall within <=2 iters (not 5)"
_OG_VERDICT="fail"
_run_cycle "stall"
assert_eq "[SPEC-3] cycle rc=2 (plateau-class soft-continue)" "2" "$_RUN_RC"
assert_eq "[SPEC-3] terminated reason is stalled" "stalled" "${_CYCLE_LAST_TERMINATED_REASON:-}"
[[ "${_CYCLE_LAST_ITERATIONS:-0}" -le 2 ]] \
    && assert_pass "[SPEC-3] terminates within <=2 iterations (got ${_CYCLE_LAST_ITERATIONS:-?}, NOT 5)" \
    || assert_fail "[SPEC-3] terminates within <=2 iterations" "ran ${_CYCLE_LAST_ITERATIONS:-?}"
assert_contains "[SPEC-3] cycle.stalled event emitted" "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.stalled"

print_test_section "SPEC-4: empty_diff + gate=pass ⇒ converged (no false stall)"
_OG_VERDICT="pass"
_run_cycle "converge"
assert_eq "[SPEC-4] cycle rc=0 (converged)" "0" "$_RUN_RC"
assert_eq "[SPEC-4] terminated reason is converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "[SPEC-4] converges at iter 1 (single-pass empty_diff NOT misclassified)" \
    "1" "${_CYCLE_LAST_ITERATIONS:-}"
if grep -q 'cycle.stalled' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-4] no cycle.stalled event on a clean converge" "cycle.stalled emitted"
else
    assert_pass "[SPEC-4] no cycle.stalled event on a clean converge"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
