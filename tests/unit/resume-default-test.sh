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
# R4 [change] hydrate under ZBUILD_RESUME=0 restores nothing — and still adopts
#             the saved history, so the next snapshot extends it instead of
#             force-pushing a new one over it (review #2229)
# R5 [change] design always makes its model call, even for a prior design that
#             passed design-gate and spec-coverage on the same issue text — it
#             emits no design.reused, and the prior design reaches the prompt as
#             a reference to check, not as this run's design (#2299, ADR-050 §6).
#             #2035 run 37289704344 kept an untested design in 1 second.
# R6–R11 [guard] design runs in each case the old reuse rule turned on:
#             ZBUILD_RESUME=0, changed issue text, a finding nobody owned (R8),
#             an ordinary failed gate (R8b), a rewind, an uncovered spec, and
#             a gate pass for a different design.md.
#             With the reuse rule gone no code path tells these apart: each
#             one guards against a skip coming back under that condition.
# R12 [change] design-gate records the hash of the design.md it judged
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
assert_eq "[R4] nothing is restored — the saved history is still fetched and adopted" "fetch adopt " "$(tr '\n' ' ' < "$_calls")"
assert_contains "[R4] ...and the result says why" \
    "$(jq -r '.reason // empty' "$_H/state/artifacts/hydrate-result.json" 2>/dev/null)" "--no-resume"

print_test_section "R5–R11: design always runs"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
MODEL_CALLS="$TEST_TEMP_DIR/design-model-calls"; : > "$MODEL_CALLS"
DESIGN_EVENTS="$TEST_TEMP_DIR/design-events"; : > "$DESIGN_EVENTS"
route_to_model_loop() {
    echo call >> "$MODEL_CALLS"
    cp "$2" "$MOCK_PROMPT_COPY" 2>/dev/null || true
    # A complete design (scope + acceptance), so the stage reaches its success path.
    printf '# Design (fresh)\n\n```scope\nfoo.sh\n```\n\n```acceptance\nSPEC-1[change]: an empty input returns rc 1\nWIRING: none\nTESTFILES:\nSPEC-1: tests/unit/resume-default-test.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
_route_loop_close_final_banner() { return 0; }
emit_event() { printf '%s\n' "$1" >> "$DESIGN_EVENTS"; return 0; }

FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX"
git -C "$FIX" init -q; git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t
printf 'x\n' > "$FIX/foo.sh"; git -C "$FIX" add -A; git -C "$FIX" commit -qm seed
export ZBUILD_REPO_ROOT="$FIX"

# _design_case <name> [prior-gate-fault] [resume] [goal-now] [existing-design] [coverage] [sha-mismatch] — prints model calls.
_design_case() {
    local d="$TEST_TEMP_DIR/$1" fault="${2:-}" resume="${3:-1}" goal="${4:-Migrate the thing.}" existing="${5:-}"
    local coverage="${6:-covered}" mismatch="${7:-}"
    local ad="$d/state/artifacts" rr="$d/state/restored-artifacts"
    mkdir -p "$ad" "$rr/artifacts"
    printf 'scope: all\n' > "$d/state/scope-manifest.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' > "$ad/plan.json"
    printf '%s\n' "$goal" > "$d/state/intake.md"
    printf 'Migrate the thing.\n' > "$rr/intake.md"
    printf '# Design (prior)\n\n```scope\nfoo.sh\n```\n' > "$rr/artifacts/design.md"
    local _sha; _sha="$(git hash-object "$rr/artifacts/design.md")"
    [[ -n "$mismatch" ]] && _sha="0000000000000000000000000000000000000000"
    jq -n --arg sha "$_sha" '{result_contract:2,verdict:"pass",disposition:"complete",reason:"build-ready",data:{design_sha:$sha}}' > "$rr/artifacts/design-gate-result.json"
    jq -n --arg v "$coverage" '{result_contract:2,verdict:$v,disposition:"complete",reason:"x"}' > "$rr/artifacts/spec-coverage-result.json"
    # #2271: $2 = unowned → the prior run stopped on a finding nobody owned;
    # anything else → an ordinary failed gate, which is no reason to redo design.
    if [[ "$fault" == "unowned" ]]; then
        printf '# Findings no stage owns\n\n## acceptance-gate finding 1 (opened by acceptance-gate)\n' > "$rr/artifacts/unowned-findings.md"
    elif [[ -n "$fault" ]]; then
        printf '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x"}\n' > "$rr/artifacts/gate-aggregator-result.json"
    fi
    [[ -n "$existing" ]] && printf '# Design (this run)\n' > "$ad/design.md"
    : > "$MODEL_CALLS"; : > "$DESIGN_EVENTS"
    ( cd "$FIX" && ZBUILD_STATE_DIR="$d/state" ZBUILD_RESTORED_ARTIFACTS_DIR="$rr/artifacts" ZBUILD_RESUME="$resume" \
        MOCK_DESIGN_WRITE_PATH="$ad/design.md" MOCK_PROMPT_COPY="$d/prompt-seen.txt" \
        _design_stage_run_inner "$d/state/scope-manifest.md" "$ad/plan.json" "$ad/design.md" "$ad" ) >/dev/null 2>&1
    echo "$?" > "$d/stage-rc"
    wc -l < "$MODEL_CALLS" | tr -d ' '
}

assert_eq "[R5] a prior design that passed both checks on the same issue text — design still makes its model call" "1" "$(_design_case r5)"
if grep -qx 'design.reused' "$DESIGN_EVENTS"; then
    assert_fail "[R5] ...and emits no design.reused" "design.reused was emitted"
else
    assert_pass "[R5] ...and emits no design.reused"
fi
assert_eq "[R5] ...and the design stage finishes successfully" "0" "$(cat "$TEST_TEMP_DIR/r5/stage-rc" 2>/dev/null)"
assert_contains "[R5] ...this run's design is the one the model wrote" \
    "$(cat "$TEST_TEMP_DIR/r5/state/artifacts/design.md" 2>/dev/null)" "Design (fresh)"
_r5_prompt="$(cat "$TEST_TEMP_DIR/r5/prompt-seen.txt" 2>/dev/null)"
assert_contains "[R5] ...the prior design reaches the prompt" "$_r5_prompt" "# Design (prior)"
assert_contains "[R5] ...as a reference to check, not a fact" "$_r5_prompt" "## PRIOR DESIGN (a previous attempt on this issue — a hypothesis, not a fact)"
assert_eq "[R6] under ZBUILD_RESUME=0 design runs" "1" "$(_design_case r6 "" 0)"
assert_eq "[R7] when the issue text changed design runs" "1" "$(_design_case r7 "" 1 "Migrate the OTHER thing.")"
assert_eq "[R8] when the prior run stopped on a finding nobody owned, design runs" "1" "$(_design_case r8 unowned)"
assert_eq "[R8b] after an ordinary failed gate, design runs" "1" "$(_design_case r8b failed)"
assert_eq "[R9] when this run already has a design (a rewind), design runs" "1" "$(_design_case r9 "" 1 "Migrate the thing." yes)"
assert_eq "[R10] when the prior spec-coverage said uncovered, design runs" "1" "$(_design_case r10 "" 1 "Migrate the thing." "" uncovered)"
assert_eq "[R11] when the gate's pass was for a different design.md, design runs" "1" "$(_design_case r11 "" 1 "Migrate the thing." "" covered yes)"

print_test_section "R12: design-gate records what it judged"
_G="$TEST_TEMP_DIR/gate/state"; mkdir -p "$_G/artifacts"
printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_G/artifacts/design.md"
printf '{}' > "$_G/pipeline-state.json"
( source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh" >/dev/null 2>&1
  emit_event() { :; }; eb_emit_event() { :; }
  unset ZBUILD_STAGE_INPUTS
  design_gate_run design-gate "$_G/pipeline-state.json" ) >/dev/null 2>&1 || true
assert_eq "[R12] design-gate-result.json carries the judged design's hash" \
    "$(git hash-object "$_G/artifacts/design.md")" \
    "$(jq -r '.data.design_sha // empty' "$_G/artifacts/design-gate-result.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
