#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/test_assessment — LLM-interprets-test-results stage (#567) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Pattern 1 (ADR-018) one-shot agent. Reads test-results.json + plan.json +
# build-summary.json; sends a redacted prompt through the T2 router; emits
# test-assessment.json + test-assessment.md.
#
# Verdict enum: pass|fail|error|inconclusive. The pass invariant
# (test.failed==0 AND agrees_with_build_complete AND build.verdict==pass)
# is enforced by the stage — an LLM "pass" without those preconditions is
# downgraded to inconclusive and a downgrade event is emitted.
#
# Cycle-iter handling: when ZBUILD_CYCLE_ID and ZBUILD_CYCLE_ITER are set the
# artifact is also written under
#   ${state_dir}/cycle-${ZBUILD_CYCLE_ID}/iter-${ZBUILD_CYCLE_ITER}/
# so iter history is preserved across _cycle_pre_iter_cleanup wipes.
#
# Manifest: plugins/agent/test_assessment/manifest.yaml
# ADR refs: ADR-001 (plugin contract), ADR-004 (redaction), ADR-013 (stage
#           list), ADR-018 (Pattern 1 one-shot with tools).

[[ -n "${_ZBUILD_TEST_ASSESSMENT_LOADED:-}" ]] && return 0
_ZBUILD_TEST_ASSESSMENT_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_TEST_ASSESSMENT_DIR="$_ZBUILD_PLUGIN_DIR"
_TEST_ASSESSMENT_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_TEST_ASSESSMENT_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_TEST_ASSESSMENT_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_TEST_ASSESSMENT_ROOT/core/router/route.sh"
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/artifact-render.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
# Wave 15-C / #681: defense-in-depth — the test plugin already sanitizes,
# but a second pass here protects against future test-results.json shapes
# (e.g. cycle-iter mirrors that side-channel an unsanitized field).
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/test-output-sanitize.sh"

# Cap on test_output bytes embedded in the prompt — keep tail so the most
# recent (typically most-failure-revealing) lines survive truncation.
: "${ZBUILD_TEST_ASSESSMENT_OUTPUT_BYTES:=16384}"

_TEST_ASSESSMENT_VALID_VERDICTS="pass fail error inconclusive"

# ─── init ───────────────────────────────────────────────────────────────────
test_assessment_init() {
    export ZBUILD_PLUGIN="test_assessment"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=test_assessment"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
# Hook called by the pipeline runner: test_assessment_run(stage, state_file)
test_assessment_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "test_assessment_run: state_file argument required"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    _test_assessment_run_inner \
        "$state_dir/scope-manifest.md" \
        "$artifact_dir/test-results.json" \
        "$artifact_dir/plan.json" \
        "$artifact_dir/build-summary.json" \
        "$artifact_dir/test-assessment.json" \
        "$artifact_dir/test-assessment.md" \
        "$artifact_dir" \
        "$state_dir"
}

# Inner: explicit-path unit-testable form.
# Args:
#   $1 = scope_manifest
#   $2 = test-results.json path
#   $3 = plan.json path
#   $4 = build-summary.json path
#   $5 = output test-assessment.json path (flat / manifest primary)
#   $6 = output test-assessment.md path (flat / manifest primary)
#   $7 = artifact_dir (for intermediate redaction files)
#   $8 = state_dir   (for cycle-iter artifact mirror)
_test_assessment_run_inner() {
    local scope_manifest="$1"
    local test_results_path="$2"
    local plan_path="$3"
    local build_summary_path="$4"
    local output_json="$5"
    local output_md="$6"
    local artifact_dir="${7:-$(dirname "$output_json")}"
    local state_dir="${8:-$(dirname "$artifact_dir")}"

    mkdir -p "$artifact_dir"

    # ─── Gather inputs ───────────────────────────────────────────────────────
    # Fail-CLOSED on missing/malformed test-results.json (#627). Before this
    # guard the plugin substituted '{}' and called the LLM with empty context,
    # producing fabricated assessments. The input is declared required:true in
    # the manifest; runtime must honor the contract or block the cycle.
    local test_content plan_content build_content
    if [[ ! -f "$test_results_path" ]]; then
        warn "test_assessment_run: test-results.json missing at $test_results_path — fail-CLOSED"
        emit_event "test_assessment.missing_input" \
            "plugin=test_assessment" \
            "path=$test_results_path" \
            "reason=missing" 2>/dev/null || true
        _test_assessment_write_error_result \
            "$output_json" "$output_md" \
            "test_results_missing" \
            "test-results.json was not written by the test stage" \
            "$state_dir"
        return 0
    fi
    test_content="$(cat "$test_results_path")"
    # Empty file is also a structural failure (jq empty accepts empty input,
    # so we must check explicitly). Require a parseable JSON document.
    if [[ -z "$test_content" ]] || ! printf '%s' "$test_content" | jq -e 'type' >/dev/null 2>&1; then
        warn "test_assessment_run: test-results.json malformed at $test_results_path — fail-CLOSED"
        emit_event "test_assessment.missing_input" \
            "plugin=test_assessment" \
            "path=$test_results_path" \
            "reason=malformed" 2>/dev/null || true
        _test_assessment_write_error_result \
            "$output_json" "$output_md" \
            "test_results_malformed" \
            "test-results.json is not valid JSON" \
            "$state_dir"
        return 0
    fi
    if [[ -f "$plan_path" ]]; then
        plan_content="$(cat "$plan_path")"
    else
        warn "test_assessment_run: plan.json missing at $plan_path"
        plan_content='{}'
    fi
    if [[ -f "$build_summary_path" ]]; then
        build_content="$(cat "$build_summary_path")"
    else
        build_content='{}'
    fi

    # Derive fields used by the invariant and the prompt header.
    local test_verdict test_failed test_passed test_output
    test_verdict="$(printf '%s' "$test_content" | jq -r '.verdict // "unknown"' 2>/dev/null || echo unknown)"
    test_failed="$(printf '%s' "$test_content" | jq -r '.failed // 0' 2>/dev/null || echo 0)"
    test_passed="$(printf '%s' "$test_content" | jq -r '.passed // 0' 2>/dev/null || echo 0)"
    test_output="$(printf '%s' "$test_content" | jq -r '.test_output // ""' 2>/dev/null || echo "")"
    # Wave 15-C (#681): sanitize before prompt splice. Idempotent — if the
    # test plugin already stripped decoration this is a no-op.
    test_output="$(printf '%s' "$test_output" | _zbuild_sanitize_test_output)"

    local build_verdict build_iters build_term
    build_verdict="$(printf '%s' "$build_content" | jq -r '.verdict // "unknown"' 2>/dev/null || echo unknown)"
    build_iters="$(printf '%s' "$build_content" | jq -r '.iterations // 0' 2>/dev/null || echo 0)"
    build_term="$(printf '%s' "$build_content" | jq -r '.terminated_reason // "complete"' 2>/dev/null || echo complete)"

    local numstat
    numstat="$(branch_numstat 2>/dev/null || echo unknown)"

    # Truncate test_output (keep tail).
    local output_bytes="$ZBUILD_TEST_ASSESSMENT_OUTPUT_BYTES"
    if [[ ${#test_output} -gt $output_bytes ]]; then
        test_output="…[truncated head]…${test_output: -$output_bytes}"
    fi

    # Render plan + assembly of human-readable context.
    local plan_md
    plan_md="$(render_artifact plan "$plan_content" 2>/dev/null || printf '%s' "$plan_content")"

    # ─── Compose prompt ──────────────────────────────────────────────────────
    # Static heredoc — no expansion. Schema and contract live inline.
    local _ta_instructions
    _ta_instructions="$(cat <<'TA_PROMPT'
You are a test-results assessment agent. Examine the test output in light of
the plan and the build claim, then produce a structured JSON verdict.

Tool use:
- You may use the Read tool to inspect files referenced in the plan or in the
  test output. Do NOT call Edit, Write, or Bash. This stage is read-only.

Output contract:
- Your FINAL response must be a SINGLE JSON object — no markdown code fences,
  no commentary before or after the JSON.
- Your response MUST begin with `{` and contain nothing other than the JSON object.

Required JSON schema:

  {
    "schema_version": 1,
    "verdict": "pass" | "fail" | "error" | "inconclusive",
    "summary": "<one-paragraph synthesis>",
    "diagnosis": "<root-cause analysis if not pass; empty string if pass>",
    "required_changes": ["<actionable change>", "..."],
    "agrees_with_build_complete": true | false,
    "branch_numstat": "<verbatim from input>",
    "failure_summary_md": "<markdown report fed back to the build stage>",
    "iter": <integer>
  }

Verdict semantics:
  pass          — tests pass AND build genuinely complete AND your reasoning
                  finds no contradicting evidence.
  fail          — tests fail with a recoverable diagnosis; build should iter.
  error         — environment/infra/diff-apply error; not a test-logic issue.
  inconclusive  — evidence is ambiguous, or you cannot tell whether the build
                  is making progress; treat as a soft block on cycle progress.

Rules:
- agrees_with_build_complete is true ONLY if the build's claimed verdict
  matches reality as visible in the test output.
- failure_summary_md is the artifact the build stage reads next iter; write
  the markdown body you want the next build prompt to see.
- branch_numstat MUST be copied verbatim from the BRANCH NUMSTAT field below.

TA_PROMPT
)"

    local prompt
    printf -v prompt '%s\n\nPLAN:\n%s\n\nBUILD CLAIM:\n verdict=%s iterations=%s terminated_reason=%s\n\nBRANCH NUMSTAT:\n%s\n\nTEST SUMMARY:\n verdict=%s passed=%s failed=%s\n\nTEST OUTPUT (verbatim, possibly truncated):\n%s\n' \
        "$_ta_instructions" \
        "$plan_md" \
        "$build_verdict" "$build_iters" "$build_term" \
        "$numstat" \
        "$test_verdict" "$test_passed" "$test_failed" \
        "$test_output"

    # ─── Redaction chokepoint (ADR-004, required) ────────────────────────────
    local prompt_file="$artifact_dir/test-assessment-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"
    local redacted_file="$artifact_dir/test-assessment-prompt.redacted.txt"
    if ! apply_scope_redaction "$prompt_file" "$redacted_file" \
        "$scope_manifest" "" "${ZBUILD_CYCLE_ID:-0}"; then
        error "test_assessment_run: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=test_assessment" "reason=redaction_failed"
        return 1
    fi
    local redacted_prompt
    redacted_prompt="$(cat "$redacted_file")"

    # ─── Route to LLM (T2) with env save/restore ─────────────────────────────
    local tier="${ZBUILD_TEST_ASSESSMENT_TIER:-T2}"
    local raw_response="" router_rc=0
    local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
    export ZBUILD_ROUTER_JSON_OUTPUT=1
    local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
    export ZBUILD_ROUTER_ARTIFACT_ID=test_assessment

    raw_response="$(route_to_model "$tier" "$redacted_prompt")" || router_rc=$?

    if [[ "$_prev_json_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_JSON_OUTPUT
    else
        export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
    fi
    if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
        unset ZBUILD_ROUTER_ARTIFACT_ID
    else
        export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
    fi

    # ─── Classify router outcome ─────────────────────────────────────────────
    if [[ $router_rc -eq 0 && -z "$raw_response" ]]; then
        error "test_assessment_run: router rc=0 with empty envelope"
        emit_event "plugin.run.error" "plugin=test_assessment" \
            "reason=empty_result_envelope"
        return 1
    fi
    if [[ $router_rc -eq 1 ]]; then
        warn "test_assessment_run: router rc=1 (recoverable); no artifact"
        emit_event "plugin.run.error" "plugin=test_assessment" \
            "reason=router_recoverable" "router_rc=1"
        return 1
    fi
    if [[ $router_rc -ne 0 ]]; then
        error "test_assessment_run: router rc=$router_rc (fatal)"
        emit_event "plugin.run.error" "plugin=test_assessment" \
            "reason=router_fatal" "router_rc=$router_rc"
        return 1
    fi

    # ─── Parse + schema-validate ─────────────────────────────────────────────
    local stripped
    stripped="$(printf '%s' "$raw_response" | extract_first_json_object)"
    local schema_expr='type=="object"
        and (.schema_version == 1)
        and (.verdict | IN("pass","fail","error","inconclusive"))
        and (.summary | type=="string")
        and (.required_changes | type=="array")
        and (.required_changes | all(type=="string"))
        and (.agrees_with_build_complete | type=="boolean")'
    if ! printf '%s' "$stripped" | jq -e "$schema_expr" >/dev/null 2>&1; then
        error "test_assessment_run: LLM response failed schema validation"
        emit_event "plugin.run.error" "plugin=test_assessment" \
            "reason=schema_violation"
        return 1
    fi

    # ─── Stage-enforced invariant: pass requires preconditions ──────────────
    local llm_verdict llm_agrees
    llm_verdict="$(printf '%s' "$stripped" | jq -r '.verdict' 2>/dev/null)"
    llm_agrees="$(printf '%s' "$stripped" | jq -r '.agrees_with_build_complete' 2>/dev/null)"

    local final_verdict="$llm_verdict"
    local downgraded=0
    if [[ "$llm_verdict" == "pass" ]]; then
        local ok=1
        # test.failed must be 0
        if [[ "$test_failed" =~ ^[0-9]+$ ]]; then
            (( test_failed != 0 )) && ok=0
        fi
        [[ "$llm_agrees" != "true" ]] && ok=0
        [[ "$build_verdict" != "pass" ]] && ok=0
        if [[ $ok -eq 0 ]]; then
            final_verdict="inconclusive"
            downgraded=1
            emit_event "test_assessment.downgrade" \
                "plugin=test_assessment" \
                "from=pass" \
                "to=inconclusive" \
                "reason=build_test_disagreement" \
                "test_failed=$test_failed" \
                "build_verdict=$build_verdict" \
                "agrees=$llm_agrees"
        fi
    fi

    # Rewrite verdict + (when downgraded) append a required_changes note,
    # then ensure branch_numstat is the helper's verbatim line. failure_summary_md
    # is preserved as the LLM emitted it (the build feedback body).
    local downgrade_note=""
    if [[ $downgraded -eq 1 ]]; then
        downgrade_note="verdict downgraded: build/test disagreement (test_failed=$test_failed agrees=$llm_agrees build_verdict=$build_verdict)"
    fi

    local final_json
    final_json="$(printf '%s' "$stripped" | jq \
        --arg v "$final_verdict" \
        --arg ns "$numstat" \
        --arg note "$downgrade_note" \
        '.verdict = $v
         | .branch_numstat = $ns
         | (if ($note | length) > 0
              then .required_changes = (.required_changes + [$note])
              else .
            end)' 2>/dev/null)"
    if [[ -z "$final_json" ]]; then
        error "test_assessment_run: jq rewrite produced empty output"
        emit_event "plugin.run.error" "plugin=test_assessment" \
            "reason=postprocess_failed"
        return 1
    fi

    # ─── Render markdown sibling ─────────────────────────────────────────────
    local rendered_md
    rendered_md="$(render_test_assessment_md "$final_json")"

    # ─── Atomic write: flat (manifest primary) ───────────────────────────────
    printf '%s\n' "$final_json" | atomic_write "$output_json"
    printf '%s\n' "$rendered_md" | atomic_write "$output_md"

    # ─── Cycle-iter mirror (survives _cycle_pre_iter_cleanup) ────────────────
    if [[ -n "${ZBUILD_CYCLE_ID:-}" && -n "${ZBUILD_CYCLE_ITER:-}" ]]; then
        local iter_dir="$state_dir/cycle-${ZBUILD_CYCLE_ID}/iter-${ZBUILD_CYCLE_ITER}"
        mkdir -p "$iter_dir"
        printf '%s\n' "$final_json"  | atomic_write "$iter_dir/test-assessment.json"
        printf '%s\n' "$rendered_md" | atomic_write "$iter_dir/test-assessment.md"
    fi

    emit_event "plugin.run.complete" "stage=test_assessment" \
        "plugin=test_assessment" \
        "verdict=$final_verdict" \
        "downgraded=$downgraded" \
        "artifact=test-assessment.json"
    return 0
}

# ─── fail-CLOSED error result writer (#627) ─────────────────────────────────
# Writes a valid test-assessment.json (verdict=error) + markdown sibling when
# the test-results.json input is missing or malformed. The verdict=error value
# is preserved by runner_read_stage_verdict (verdict.sh:#550) and triggers
# _cycle_detect_blocked so the cycle aborts at the current iteration instead
# of burning further iterations on fabricated assessments.
#
# Args:
#   $1 = output test-assessment.json path
#   $2 = output test-assessment.md path
#   $3 = reason code (test_results_missing | test_results_malformed)
#   $4 = human-readable detail
#   $5 = state_dir (for optional cycle-iter mirror)
_test_assessment_write_error_result() {
    local output_json="$1"
    local output_md="$2"
    local reason="$3"
    local detail="$4"
    local state_dir="$5"

    local final_json
    final_json="$(jq -nc \
        --arg reason "$reason" \
        --arg detail "$detail" \
        '{
            schema_version: 1,
            verdict: "error",
            reason: $reason,
            detail: $detail,
            summary: $detail,
            diagnosis: "",
            required_changes: [],
            agrees_with_build_complete: false,
            branch_numstat: "unknown",
            failure_summary_md: ("test_assessment fail-CLOSED: " + $detail),
            iter: 0
        }')"

    local rendered_md
    rendered_md="$(render_test_assessment_md "$final_json" 2>/dev/null || \
        printf '# Test Assessment: error\n\n%s\n' "$detail")"

    printf '%s\n' "$final_json" | atomic_write "$output_json"
    printf '%s\n' "$rendered_md" | atomic_write "$output_md"

    if [[ -n "${ZBUILD_CYCLE_ID:-}" && -n "${ZBUILD_CYCLE_ITER:-}" ]]; then
        local iter_dir="$state_dir/cycle-${ZBUILD_CYCLE_ID}/iter-${ZBUILD_CYCLE_ITER}"
        mkdir -p "$iter_dir"
        printf '%s\n' "$final_json"  | atomic_write "$iter_dir/test-assessment.json"
        printf '%s\n' "$rendered_md" | atomic_write "$iter_dir/test-assessment.md"
    fi

    emit_event "plugin.run.complete" "stage=test_assessment" \
        "plugin=test_assessment" \
        "verdict=error" \
        "reason=$reason" \
        "artifact=test-assessment.json" 2>/dev/null || true
}

# ─── finalize ───────────────────────────────────────────────────────────────
test_assessment_finalize() {
    emit_event "plugin.finalize.complete" "plugin=test_assessment"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
test_assessment_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=test_assessment"
    return 0
}
