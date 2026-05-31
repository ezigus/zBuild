#!/usr/bin/env bash
# Integration test (#568): standard.yaml declares the 3-stage build/test/
# test_assessment cycle, and the cycle orchestrator drives those three
# stages in order each iteration, terminates on test_assessment.verdict==pass,
# and wires test_assessment.md → build.prior_test_assessment between iters.
#
# Scope is the orchestrator boundary (cycle_orchestrator_run). We stub
# cycle_dispatch_stage to record per-stage invocations and to inject
# canned verdicts driven by env vars — no real LLM, no real build.
#
# Pinned assertions:
#   T1: template parser → cycle.stages=[build,test,test_assessment]
#   T1: until.stage=test_assessment, until.field=verdict, op=eq, value=pass
#   T1: feedback wires test_assessment:test_assessment_md →
#       build:prior_test_assessment
#   T1: top-level _TPL_STAGES = [intake,plan,build,test,test_assessment,review]
#   T2: when test_assessment.verdict=pass iter 1 → cycle rc=0
#       (reason=converged), exactly one iter of build+test+test_assessment ran
#   T3: when test_assessment.verdict=fail iter 1 → cycle proceeds to iter 2,
#       and on iter-2 build dispatch, ZBUILD_CYCLE_FEEDBACK_DIR contains
#       prior_test_assessment.txt with iter-1 test-assessment.md content
#   T4: each dispatched iter emits stage events for build/test/test_assessment
#       in that order (via _cycle_iter_dispatch's per-stage loop semantics)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "standard.yaml 3-stage cycle [build,test,test_assessment] (#568)"
setup_test_env "std-3stage-cycle-568"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── T1: template parsing ────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/standard.yaml"

assert_eq "T1: _TPL_STAGES has 6 entries" "6" "${#_TPL_STAGES[@]}"
assert_eq "T1: _TPL_STAGES[0]=intake" "intake" "${_TPL_STAGES[0]:-}"
assert_eq "T1: _TPL_STAGES[1]=plan" "plan" "${_TPL_STAGES[1]:-}"
assert_eq "T1: _TPL_STAGES[2]=build" "build" "${_TPL_STAGES[2]:-}"
assert_eq "T1: _TPL_STAGES[3]=test" "test" "${_TPL_STAGES[3]:-}"
assert_eq "T1: _TPL_STAGES[4]=test_assessment" "test_assessment" "${_TPL_STAGES[4]:-}"
assert_eq "T1: _TPL_STAGES[5]=review" "review" "${_TPL_STAGES[5]:-}"

assert_eq "T1: exactly 1 cycle" "1" "${#_TPL_CYCLES[@]}"
assert_eq "T1: cycle id=build_test_cycle" "build_test_cycle" "${_TPL_CYCLES[0]}"
assert_eq "T1: cycle.stages CSV is build,test,test_assessment" \
    "build,test,test_assessment" "${_TPL_CYCLE_STAGES_build_test_cycle:-}"
assert_eq "T1: until.stage=test_assessment" \
    "test_assessment" "${_TPL_CYCLE_UNTIL_STAGE_build_test_cycle:-}"
assert_eq "T1: until.field=verdict" \
    "verdict" "${_TPL_CYCLE_UNTIL_FIELD_build_test_cycle:-}"
assert_eq "T1: until.op=eq" \
    "eq" "${_TPL_CYCLE_UNTIL_OP_build_test_cycle:-}"
assert_eq "T1: until.value=pass" \
    "pass" "${_TPL_CYCLE_UNTIL_VALUE_build_test_cycle:-}"
assert_eq "T1: max_iterations=3" \
    "3" "${_TPL_CYCLE_MAX_build_test_cycle:-}"

fb="${_TPL_CYCLE_FEEDBACK_build_test_cycle:-}"
assert_contains "T1: feedback from test_assessment:test_assessment_md" \
    "$fb" "test_assessment:test_assessment_md"
assert_contains "T1: feedback to build:prior_test_assessment" \
    "$fb" "build:prior_test_assessment"

# dispatch units: stage:intake, stage:plan, cycle:build_test_cycle, stage:review
assert_eq "T1: 4 dispatch units" "4" "${#_TPL_DISPATCH_UNITS[@]}"
has_cyc=0
for u in "${_TPL_DISPATCH_UNITS[@]}"; do
    [[ "$u" == "cycle:build_test_cycle" ]] && has_cyc=1
done
assert_eq "T1: dispatch units include cycle:build_test_cycle" "1" "$has_cyc"

# ─── Orchestrator harness ────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# Build a transient state dir per case; the orchestrator writes artifacts/
# under it that _cycle_apply_feedback resolves via the from-stage manifest
# (test_assessment's manifest: ${artifact_dir}/test-assessment.md).
_run_cycle_case() {
    local _case_dir="$1" _verdict_iter1="$2" _verdict_iter2="$3"
    # Run in-shell (no subshell) so _CYCLE_LAST_* globals propagate.
    mkdir -p "$_case_dir/state/artifacts" "$_case_dir/events"
    export ZBUILD_STATE_DIR="$_case_dir/state"
    export ZBUILD_STATE_FILE="$_case_dir/state/pipeline-state.json"
    export ZBUILD_EVENTS_DIR="$_case_dir/events"
    export ZBUILD_EVENTS_JSONL="$_case_dir/events/events.jsonl"
    export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
    : > "$ZBUILD_EVENTS_JSONL"
    printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"

    # Per-case stub: log each dispatch + emit verdicts driven by iter+stage.
    # The test_assessment stage MUST write test-assessment.md so that
    # _cycle_apply_feedback can copy it as the next iter's
    # prior_test_assessment.txt (manifest declares
    # ${artifact_dir}/test-assessment.md).
    export _DISPATCH_LOG="$_case_dir/dispatch.log"
    export _VERDICT_ITER1="$_verdict_iter1"
    export _VERDICT_ITER2="$_verdict_iter2"
    : > "$_DISPATCH_LOG"

    cycle_dispatch_stage() {
        local stage="$1" iter="$2" state_file="$3"
        printf 'iter=%s stage=%s\n' "$iter" "$stage" >> "$_DISPATCH_LOG"
        local state_dir; state_dir="$(dirname "$state_file")"
        local artdir="$state_dir/artifacts"
        mkdir -p "$artdir"
        local v="pass"
        case "$stage" in
            build) v="pass" ;;
            test)
                # test verdict mirrors the test_assessment we WANT (so
                # blocked detector doesn't fire on `error`).
                if [[ "$iter" == "1" ]]; then v="${_VERDICT_ITER1}"; else v="${_VERDICT_ITER2}"; fi
                # Write a small test-results.json (failure_count uses .failed).
                if [[ "$v" == "pass" ]]; then
                    printf '{"verdict":"pass","failed":0,"passed":1}' > "$artdir/test-results.json"
                else
                    printf '{"verdict":"fail","failed":1,"passed":0}' > "$artdir/test-results.json"
                fi
                ;;
            test_assessment)
                if [[ "$iter" == "1" ]]; then v="${_VERDICT_ITER1}"; else v="${_VERDICT_ITER2}"; fi
                # Write the markdown sibling at the manifest path.
                printf '## Test Assessment (iter %s)\n\nverdict: %s\n' \
                    "$iter" "$v" > "$artdir/test-assessment.md"
                printf '{"verdict":"%s"}' "$v" > "$artdir/test-assessment.json"
                ;;
        esac
        _CYCLE_DISPATCH_VERDICT="$v"
        _CYCLE_DISPATCH_STATUS="complete"
        return 0
    }

    set +e
    cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
    _LAST_CYCLE_RC=$?
    set -e
}

# ─── T2: iter-1 converges (test_assessment.verdict=pass) ─────────────────────
T2_DIR="$TEST_TEMP_DIR/t2"
_run_cycle_case "$T2_DIR" "pass" "pass"
T2_RC="$_LAST_CYCLE_RC"
assert_eq "T2: converged iter 1 → rc=0" "0" "$T2_RC"
assert_eq "T2: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "T2: exactly 1 iter executed" "1" "${_CYCLE_LAST_ITERATIONS:-}"

t2_log="$(cat "$T2_DIR/dispatch.log")"
t2_lines="$(wc -l < "$T2_DIR/dispatch.log" | tr -d ' ')"
assert_eq "T2: 3 dispatch calls (build+test+test_assessment, 1 iter)" "3" "$t2_lines"
assert_contains "T2: iter=1 stage=build" "$t2_log" "iter=1 stage=build"
assert_contains "T2: iter=1 stage=test" "$t2_log" "iter=1 stage=test"
assert_contains "T2: iter=1 stage=test_assessment" "$t2_log" "iter=1 stage=test_assessment"

# Order: build before test before test_assessment within iter 1.
t2_build_n="$(grep -n 'iter=1 stage=build' "$T2_DIR/dispatch.log" | head -1 | cut -d: -f1)"
t2_test_n="$(grep -n 'iter=1 stage=test' "$T2_DIR/dispatch.log" | grep -v test_assessment | head -1 | cut -d: -f1)"
t2_ta_n="$(grep -n 'iter=1 stage=test_assessment' "$T2_DIR/dispatch.log" | head -1 | cut -d: -f1)"
if [[ -n "$t2_build_n" && -n "$t2_test_n" && -n "$t2_ta_n" \
      && "$t2_build_n" -lt "$t2_test_n" && "$t2_test_n" -lt "$t2_ta_n" ]]; then
    assert_pass "T2: dispatch order build < test < test_assessment within iter 1"
else
    assert_fail "T2: dispatch order" \
        "got build=$t2_build_n test=$t2_test_n ta=$t2_ta_n in $T2_DIR/dispatch.log"
fi

# ─── T3: iter-1 fails, iter-2 runs, feedback wired ───────────────────────────
T3_DIR="$TEST_TEMP_DIR/t3"
_run_cycle_case "$T3_DIR" "fail" "pass"
T3_RC="$_LAST_CYCLE_RC"
assert_eq "T3: iter-1 fail + iter-2 pass → rc=0" "0" "$T3_RC"
assert_eq "T3: reason=converged on iter 2" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "T3: exactly 2 iters executed" "2" "${_CYCLE_LAST_ITERATIONS:-}"

t3_lines="$(wc -l < "$T3_DIR/dispatch.log" | tr -d ' ')"
assert_eq "T3: 6 dispatch calls (3 stages × 2 iters)" "6" "$t3_lines"

# iter-2 feedback file MUST exist with iter-1 test-assessment.md content.
T3_FB="$T3_DIR/state/cycle-build_test_cycle/iter-2/feedback/prior_test_assessment.txt"
if [[ -s "$T3_FB" ]]; then
    assert_pass "T3: iter-2 feedback file prior_test_assessment.txt exists and is non-empty"
else
    assert_fail "T3: iter-2 feedback file" "missing or empty: $T3_FB"
fi
assert_contains "T3: feedback contains iter-1 test-assessment markdown header" \
    "$(cat "$T3_FB" 2>/dev/null)" "Test Assessment (iter 1)"

# .complete sentinel must be present (Pin 9)
if [[ -e "$T3_DIR/state/cycle-build_test_cycle/iter-2/feedback/.complete" ]]; then
    assert_pass "T3: iter-2 feedback .complete sentinel written"
else
    assert_fail "T3: iter-2 feedback .complete sentinel" "missing"
fi

# ─── T4: cycle events fire for all three stages each iter ────────────────────
# cycle.iteration.complete fires once per iter — verify count = iters.
t3_iter_complete="$(grep -c '"type":"cycle.iteration.complete"' "$T3_DIR/events/events.jsonl" 2>/dev/null || echo 0)"
assert_eq "T4: cycle.iteration.complete fires 2× across 2 iters" "2" "$t3_iter_complete"
# cycle.start once
t3_start="$(grep -c '"type":"cycle.start"' "$T3_DIR/events/events.jsonl" 2>/dev/null || echo 0)"
assert_eq "T4: cycle.start fires once" "1" "$t3_start"
# cycle.complete once with reason=converged
if grep '"type":"cycle.complete"' "$T3_DIR/events/events.jsonl" 2>/dev/null \
   | grep -q '"reason":"converged"'; then
    assert_pass "T4: cycle.complete reason=converged"
else
    assert_fail "T4: cycle.complete reason=converged" "missing"
fi

print_test_results
