#!/usr/bin/env bash
# tests/unit/resume-default-test.sh — resume by default; --no-resume recreates;
# each stage decides what to reuse (#2225 §4).
#
# Why: after a usage-limit abort, re-adding zbuild-run starts a NEW run that
# hydrate seeds with the old artifacts — but no stage is told it is a resume,
# so design runs again (~20 min, #1835 and #1837 on 2026-09-29) and the loop's
# rounds reset. The run's intent now reaches every stage the way the others do
# (ZBUILD_SELF_HOST ⇔ --self-host): one variable, ZBUILD_RESUME.
#
# R1 [change] the runner's resume intent: 1 by default, 0 with --no-resume, and
#             ZBUILD_RESUME=0 in the environment is the same as --no-resume
# R2 [change] the runner exports it before any stage runs
# R3 [change] the pipeline workflow has a no_resume input that passes --no-resume;
#             the daemon leaves it at the default
# R4 [change] hydrate under ZBUILD_RESUME=0 restores nothing and adopts no prior branch
# R5 [change] design reuses a qualifying prior design with no model call
# R6 [change] ...not under ZBUILD_RESUME=0
# R7 [change] ...not when the issue text changed
# R8 [change] ...not when the prior run sent the work back to design
# R9 [change] ...not when this run already has a design (a rewind)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resume by default; --no-resume recreates (#2225 §4)"
setup_test_env "resume-default"
unset ZBUILD_RESUME 2>/dev/null || true

print_test_section "R1/R2: the runner"
_intent="$(
    # shellcheck source=../../core/pipeline/runner.sh
    source "$REPO_ROOT/core/pipeline/runner.sh" >/dev/null 2>&1
    if declare -F _runner_resume_intent >/dev/null 2>&1; then
        printf '%s %s %s' "$(_runner_resume_intent false)" "$(_runner_resume_intent true)" \
            "$(ZBUILD_RESUME=0 _runner_resume_intent false)"
    else
        printf 'missing'
    fi
)"
assert_eq "[R1] default → 1, --no-resume → 0, ZBUILD_RESUME=0 → 0" "1 0 0" "$_intent"
if grep -qE 'export ZBUILD_RESUME' "$REPO_ROOT/core/pipeline/runner.sh"; then
    assert_pass "[R2] the runner exports ZBUILD_RESUME for the stages"
else
    assert_fail "[R2] the runner exports ZBUILD_RESUME for the stages" "no export"
fi

print_test_section "R3: the workflows"
_wf="$(cat "$REPO_ROOT/.github/workflows/zbuild-pipeline.yml")"
assert_contains "[R3] the pipeline workflow declares a no_resume input" "$_wf" "no_resume:"
assert_contains "[R3] ...and passes --no-resume when it is set" "$_wf" "args+=(--no-resume)"
if grep -q 'no_resume' "$REPO_ROOT/.github/workflows/zbuild-daemon.yml"; then
    assert_fail "[R3] the daemon leaves resume at the default" "it sets no_resume"
else
    assert_pass "[R3] the daemon leaves resume at the default"
fi

print_test_section "R4: hydrate under --no-resume"
_H="$TEST_TEMP_DIR/hydrate"; mkdir -p "$_H/state/artifacts" "$_H/events"
_calls="$TEST_TEMP_DIR/hydrate-calls"; : > "$_calls"
(
    export ZBUILD_STATE_DIR="$_H/state" ZBUILD_ARTIFACT_DIR="$_H/state/artifacts" ZBUILD_ISSUE="$(zb_test_issue)"
    export ZBUILD_EVENTS_DIR="$_H/events" ZBUILD_EVENTS_JSONL="$_H/events/events.jsonl" ZBUILD_RESUME=0
    source "$REPO_ROOT/plugins/tool/hydrate/plugin.sh" >/dev/null 2>&1
    emit_event() { :; }
    _artifact_persist_has_identity() { return 0; }
    _hydrate_fetch() { echo fetch >> "$_calls"; return 0; }
    _artifact_persist_restore() { echo restore >> "$_calls"; _ARTIFACT_PERSIST_LAST_STATUS=empty; return 0; }
    _artifact_persist_adopt_remote() { echo adopt >> "$_calls"; return 0; }
    hydrate_run hydrate "$_H/state/pipeline-state.json"
) >/dev/null 2>&1 || true
assert_eq "[R4] nothing is fetched, restored or adopted" "" "$(tr '\n' ' ' < "$_calls")"
assert_contains "[R4] ...and the result says why" \
    "$(jq -r '.reason // empty' "$_H/state/artifacts/hydrate-result.json" 2>/dev/null)" "--no-resume"

print_test_section "R5–R9: design"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
MODEL_CALLS="$TEST_TEMP_DIR/design-model-calls"; : > "$MODEL_CALLS"
route_to_model_loop() {
    echo call >> "$MODEL_CALLS"
    printf '# Design (fresh)\n\n```scope\nfoo.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
_route_loop_close_final_banner() { return 0; }

FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX"
git -C "$FIX" init -q; git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t
printf 'x\n' > "$FIX/foo.sh"; git -C "$FIX" add -A; git -C "$FIX" commit -qm seed
export ZBUILD_REPO_ROOT="$FIX"

# _design_case <name> [prior-gate-fault] [resume] [goal-now] [existing-design] — prints model calls.
_design_case() {
    local d="$TEST_TEMP_DIR/$1" fault="${2:-}" resume="${3:-1}" goal="${4:-Migrate the thing.}" existing="${5:-}"
    local ad="$d/state/artifacts" rr="$d/state/restored-artifacts"
    mkdir -p "$ad" "$rr/artifacts"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' > "$ad/plan.json"
    printf '%s\n' "$goal" > "$d/state/intake.md"
    printf 'Migrate the thing.\n' > "$rr/intake.md"
    printf '# Design (prior)\n\n```scope\nfoo.sh\n```\n' > "$rr/artifacts/design.md"
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"build-ready"}\n' > "$rr/artifacts/design-gate-result.json"
    [[ -n "$fault" ]] && printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x","fault":"%s"}\n' "$fault" > "$rr/artifacts/gate-aggregator-result.json"
    [[ -n "$existing" ]] && printf '# Design (this run)\n' > "$ad/design.md"
    : > "$MODEL_CALLS"
    ( cd "$FIX" && ZBUILD_STATE_DIR="$d/state" ZBUILD_RESTORED_ARTIFACTS_DIR="$rr/artifacts" ZBUILD_RESUME="$resume" \
        MOCK_DESIGN_WRITE_PATH="$ad/design.md" \
        _design_stage_run_inner "$d/state/scope-manifest.md" "$ad/plan.json" "$ad/design.md" "$ad" ) >/dev/null 2>&1 || true
    wc -l < "$MODEL_CALLS" | tr -d ' '
}

assert_eq "[R5] a qualifying prior design is reused — no model call" "0" "$(_design_case r5)"
assert_contains "[R5] ...its content is this run's design" "$(cat "$TEST_TEMP_DIR/r5/state/artifacts/design.md" 2>/dev/null)" "Design (prior)"
assert_eq "[R5] ...and design says it passed, reusing it" "pass" \
    "$(jq -r '.verdict // empty' "$TEST_TEMP_DIR/r5/state/artifacts/design-verdict.json" 2>/dev/null)"
assert_contains "[R5] ...naming the reuse" \
    "$(jq -r '.reason // empty' "$TEST_TEMP_DIR/r5/state/artifacts/design-verdict.json" 2>/dev/null)" "reused"
assert_eq "[R6] under ZBUILD_RESUME=0 design runs" "1" "$(_design_case r6 "" 0)"
assert_eq "[R7] when the issue text changed design runs" "1" "$(_design_case r7 "" 1 "Migrate the OTHER thing.")"
assert_eq "[R8] when the prior run sent the work back to design, design runs" "1" "$(_design_case r8 specification)"
assert_eq "[R8] ...an implementation fault is not a rewind — still reused" "0" "$(_design_case r8b implementation)"
assert_eq "[R9] when this run already has a design (a rewind), design runs" "1" "$(_design_case r9 "" 1 "Migrate the thing." yes)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
