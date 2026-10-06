#!/usr/bin/env bash
# tests/unit/earlier-run-prompt-label-test.sh — a model stage's prompt that
# carries an earlier run's saved work says it is from an earlier run, for
# reference only, and not this run's result (ADR-050 §8, #2326).
#
# The engine-side half (input index, input event, stages that judge) is
# earlier-run-reference-test.sh. This file covers the stages that seed
# themselves from their own earlier work, and the save-as-you-go notes.
#
#   L1 [change] design: a design restored from an earlier run is labelled
#   L2 [change] plan:   a plan restored from an earlier run is labelled
#   L3 [change] impact: an impact result restored from an earlier run is labelled
#   L4 [change] notes an earlier run saved (checkpoint) are labelled, under
#               their own heading, not "PRIOR EXPLORATION ... build on it"
#   L5 [change] build: an earlier run's build summary is labelled
#   Each with a [guard]: the same work from THIS run is not labelled, and the
#   earlier work still reaches the prompt (the hand-over keeps working).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "an earlier run's work is labelled in every prompt that carries it (#2326)"
setup_test_env "earlier-run-prompt-label"

unset ZBUILD_STAGE_INPUTS ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR \
      ZBUILD_RESTORED_ARTIFACTS_DIR ZBUILD_OUTER_ROUND ZBUILD_RUN_START_MARKER 2>/dev/null || true

LABEL="from an earlier run — reference only, not this run's result"

_refute_contains() {   # <label> <haystack> <needle>
    if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi
}

# ─── L1: design ─────────────────────────────────────────────────────────────
print_test_section "L1. design labels a design restored from an earlier run"
FIX="$TEST_TEMP_DIR/design-fix"; mkdir -p "$FIX"
git -C "$FIX" init -q; git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t
printf 'x\n' > "$FIX/foo.sh"; git -C "$FIX" add -A; git -C "$FIX" -c commit.gpgsign=false commit -qm init
_design_case() {   # <name> <restored dir or ""> <feedback dir or ""> → prints the prompt path
    local st="$FIX/$1"; mkdir -p "$st/artifacts"; printf 'scope: all\n' > "$st/scope-manifest.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' \
        > "$st/artifacts/plan.json"
    (
        # shellcheck source=../../plugins/agent/design/plugin.sh
        source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
        route_to_model_loop() {
            printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$st/artifacts/design.md"
            _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
            _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
            _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
            return 0
        }
        apply_scope_redaction() { cp "$1" "$2"; return 0; }
        _route_loop_close_final_banner() { return 0; }
        emit_event() { :; }; eb_emit_event() { :; }
        export ZBUILD_REPO_ROOT="$FIX"
        [[ -n "$2" ]] && export ZBUILD_RESTORED_ARTIFACTS_DIR="$2"
        [[ -n "$3" ]] && export ZBUILD_CYCLE_ITER=2 ZBUILD_CYCLE_FEEDBACK_DIR="$3"
        cd "$FIX" && _design_stage_run_inner "$st/scope-manifest.md" "$st/artifacts/plan.json" \
            "$st/artifacts/design.md" "$st/artifacts"
    ) >/dev/null 2>&1
    printf '%s' "$st/artifacts/design-prompt.txt"
}
D_RESTORED="$TEST_TEMP_DIR/design-restored"; mkdir -p "$D_RESTORED"
printf '# Design\n\nDESIGN-FROM-EARLIER-RUN\n\n```scope\nfoo.sh\n```\n' > "$D_RESTORED/design.md"
P1="$(cat "$(_design_case l1 "$D_RESTORED" "")" 2>/dev/null)"
assert_contains "[L1] the earlier design still reaches the prompt" "$P1" "DESIGN-FROM-EARLIER-RUN"
assert_contains "[L1] ...labelled as from an earlier run" "$P1" "$LABEL"
D_FB="$TEST_TEMP_DIR/design-fb"; mkdir -p "$D_FB"
printf '# Design\n\nDESIGN-FROM-THIS-RUN\n\n```scope\nfoo.sh\n```\n' > "$D_FB/design.txt"
P1g="$(cat "$(_design_case l1g "" "$D_FB")" 2>/dev/null)"
assert_contains "[L1-guard] a design from this run reaches the prompt" "$P1g" "DESIGN-FROM-THIS-RUN"
_refute_contains "[L1-guard] ...and is not labelled as an earlier run's" "$P1g" "$LABEL"

# ─── L2: plan ───────────────────────────────────────────────────────────────
print_test_section "L2. plan labels a plan restored from an earlier run"
_plan_case() {   # <name> <restored dir> <this run's plan or ""> → prints the captured prompt
    local d="$TEST_TEMP_DIR/plan-$1"; mkdir -p "$d"
    (
        TEST_TEMP_DIR="$d"
        # shellcheck source=../../plugins/agent/plan/tests/plan-test-lib.sh
        source "$REPO_ROOT/plugins/agent/plan/tests/plan-test-lib.sh" >/dev/null 2>&1
        export ZBUILD_STATE_DIR="$STATE_DIR" ZBUILD_RESTORED_ARTIFACTS_DIR="$2"
        PLAN_GOAL="test goal"
        [[ -n "$3" ]] && printf '%s\n' "$3" > "$ARTIFACTS_DIR/plan.json"
        _run_plan "$STATE_FILE" >/dev/null 2>&1
        cat "$_CAPTURED_PROMPT_FILE"
    ) 2>/dev/null
}
P_RESTORED="$TEST_TEMP_DIR/plan-restored"; mkdir -p "$P_RESTORED"
printf '{"title":"PLAN-FROM-EARLIER-RUN","steps":[]}\n' > "$P_RESTORED/plan.json"
P2="$(_plan_case l2 "$P_RESTORED" "")"
assert_contains "[L2] the earlier plan still reaches the prompt" "$P2" "PLAN-FROM-EARLIER-RUN"
assert_contains "[L2] ...labelled as from an earlier run" "$P2" "$LABEL"
P2g="$(_plan_case l2g "$P_RESTORED" '{"title":"PLAN-FROM-THIS-RUN","steps":[]}')"
assert_contains "[L2-guard] this run's own plan is the one carried" "$P2g" "PLAN-FROM-THIS-RUN"
_refute_contains "[L2-guard] ...and is not labelled as an earlier run's" "$P2g" "$LABEL"

# ─── L3: impact ─────────────────────────────────────────────────────────────
print_test_section "L3. impact labels an impact result restored from an earlier run"
_impact_case() {   # <name> <restored dir> <this run's impact or ""> → prints the prompt
    local fix="$TEST_TEMP_DIR/impact-$1" ad
    ad="$fix/state/artifacts"; mkdir -p "$ad"
    git -C "$fix" init -q >/dev/null 2>&1
    printf '# Scope\n- x.sh\n' > "$fix/state/scope-manifest.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["x.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' > "$ad/plan.json"
    printf '# Design\n\n```scope\nx.sh\n```\n' > "$ad/design.md"
    [[ -n "$3" ]] && printf '%s\n' "$3" > "$ad/impact.json"
    (
        # shellcheck source=../../plugins/agent/impact/plugin.sh
        source "$REPO_ROOT/plugins/agent/impact/plugin.sh" >/dev/null 2>&1
        route_to_model() { printf '%s' '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}'; }
        apply_scope_redaction() { cp "$1" "$2"; return 0; }
        emit_event() { :; }; eb_emit_event() { :; }
        resolve_tier() { printf 'T2'; }
        _impact_scope_prefilter() { printf '[]'; }
        _impact_envelope_schema_ok() { return 0; }
        _impact_drop_nonexistent_missing() { return 0; }
        _impact_converge_on_overscope() { return 0; }
        append_prompt_override() { return 0; }
        export ZBUILD_REPO_ROOT="$fix" ZBUILD_STATE_DIR="$fix/state" ZBUILD_RESTORED_ARTIFACTS_DIR="$2"
        _impact_run_inner "$fix/state/scope-manifest.md" "$ad/design.md" "$ad/plan.json" \
            "$ad/impact-out.json" "$ad"
    ) >/dev/null 2>&1
    cat "$ad/impact-prompt.txt" 2>/dev/null
}
I_RESTORED="$TEST_TEMP_DIR/impact-restored"; mkdir -p "$I_RESTORED"
printf '{"verdict":"complete","impact_feedback_md":"IMPACT-FROM-EARLIER-RUN"}\n' > "$I_RESTORED/impact.json"
P3="$(_impact_case l3 "$I_RESTORED" "")"
assert_contains "[L3] the earlier impact result still reaches the prompt" "$P3" "IMPACT-FROM-EARLIER-RUN"
assert_contains "[L3] ...labelled as from an earlier run" "$P3" "$LABEL"
P3g="$(_impact_case l3g "$I_RESTORED" '{"verdict":"complete","impact_feedback_md":"IMPACT-FROM-THIS-RUN"}')"
assert_contains "[L3-guard] this run's own impact result is the one carried" "$P3g" "IMPACT-FROM-THIS-RUN"
_refute_contains "[L3-guard] ...and is not labelled as an earlier run's" "$P3g" "$LABEL"

# ─── L4: notes an earlier run saved ─────────────────────────────────────────
print_test_section "L4. notes an earlier run saved are labelled"
(
    # shellcheck source=../../scripts/lib/stage-checkpoint.sh
    source "$REPO_ROOT/scripts/lib/stage-checkpoint.sh"
    st="$TEST_TEMP_DIR/cp/state"; mkdir -p "$st/artifacts"
    m="$TEST_TEMP_DIR/cp/manifest.yaml"
    { printf 'id: fixture\nkind: agent\nversion: 0.1.0\n\noutputs:\n'
      printf '  - id: fixture-checkpoint\n    path: ${artifact_dir}/fixture-checkpoint.md\n'
      printf '    type: checkpoint.md\n    required: false\n    role: checkpoint\n'; } > "$m"
    r="$TEST_TEMP_DIR/cp/restored"; mkdir -p "$r"
    printf 'NOTES-FROM-EARLIER-RUN: Status: DONE\n' > "$r/fixture-checkpoint.md"
    ZBUILD_RESTORED_ARTIFACTS_DIR="$r" checkpoint_prompt_block "$m" "$st" > "$TEST_TEMP_DIR/cp/earlier.txt"
    printf 'NOTES-FROM-THIS-RUN\n' > "$st/artifacts/fixture-checkpoint.md"
    ZBUILD_RESTORED_ARTIFACTS_DIR="$r" checkpoint_prompt_block "$m" "$st" > "$TEST_TEMP_DIR/cp/this.txt"
) 2>/dev/null
P4="$(cat "$TEST_TEMP_DIR/cp/earlier.txt" 2>/dev/null)"
assert_contains "[L4] the earlier run's notes still reach the prompt" "$P4" "NOTES-FROM-EARLIER-RUN"
assert_contains "[L4] ...under their own heading" "$P4" "### NOTES FROM AN EARLIER RUN (reference only)"
assert_contains "[L4] ...labelled as from an earlier run" "$P4" "$LABEL"
_refute_contains "[L4] ...and not told to build on them as this stage's own exploration" "$P4" "PRIOR EXPLORATION"
P4g="$(cat "$TEST_TEMP_DIR/cp/this.txt" 2>/dev/null)"
assert_contains "[L4-guard] this run's notes read as before" "$P4g" "PRIOR EXPLORATION"
_refute_contains "[L4-guard] ...and are not labelled as an earlier run's" "$P4g" "$LABEL"

# ─── L5: build's prior summary ──────────────────────────────────────────────
print_test_section "L5. build labels an earlier run's build summary"
_build_case() {   # <restored dir> <state dir>
    (
        # shellcheck source=../../scripts/lib/prior-output-reader.sh
        source "$REPO_ROOT/scripts/lib/prior-output-reader.sh"
        # shellcheck source=../../plugins/agent/build/lib/context.sh
        source "$REPO_ROOT/plugins/agent/build/lib/context.sh"
        ZBUILD_RESTORED_ARTIFACTS_DIR="$1" ZBUILD_STATE_DIR="$2" _build_read_prior_build_summary
    ) 2>/dev/null
}
B_RESTORED="$TEST_TEMP_DIR/build-restored"; B_STATE="$TEST_TEMP_DIR/build-state"
mkdir -p "$B_RESTORED" "$B_STATE/artifacts"
printf '{"verdict":"pass","files_changed":["earlier.sh"]}\n' > "$B_RESTORED/build-summary.json"
P5="$(_build_case "$B_RESTORED" "$B_STATE")"
assert_contains "[L5] the earlier build summary still reaches the prompt" "$P5" "earlier.sh"
assert_contains "[L5] ...labelled as from an earlier run" "$P5" "$LABEL"
printf '{"verdict":"pass","files_changed":["this-run.sh"]}\n' > "$B_STATE/artifacts/build-summary.json"
P5g="$(_build_case "$B_RESTORED" "$B_STATE")"
assert_contains "[L5-guard] this run's summary is the one carried" "$P5g" "this-run.sh"
_refute_contains "[L5-guard] ...and is not labelled as an earlier run's" "$P5g" "$LABEL"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
