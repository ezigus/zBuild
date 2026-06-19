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
# ADR-028: shared LLM-agent stage framework (PR 4/5 — test_assessment migration).
# shellcheck source=../../../scripts/lib/llm-agent.sh
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/llm-agent.sh"

# ─── _ta_build_verdict_convergeable (#895) ───────────────────────────────────
# Build verdicts eligible for build_test_cycle convergence when the suite is
# green. `pass` = normal success. `empty_diff` = build emitted done_sentinel
# with 0 files changed (work already implemented) — a green suite on empty_diff
# is a legitimate convergence, not a livelock. All other verdicts
# (scope_violation, corrupt_diff, error, block, unknown) stay rejected: transient
# or structural-failure states that are not durable convergence.
# NOTE: this is the test_assessment cycle-convergence gate ONLY. The build-stage
# indicator still classifies empty_diff as `fail` via core/pipeline/verdict.sh
# (a different consumer) — that is correct and unchanged.
_ta_build_verdict_convergeable() {
    case "$1" in
        pass|empty_diff) return 0 ;;
        *)               return 1 ;;
    esac
}
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/artifact-render.sh"
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
# Wave 15-C / #681: defense-in-depth — the test plugin already sanitizes,
# but a second pass here protects against future test-results.json shapes
# (e.g. cycle-iter mirrors that side-channel an unsanitized field).
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/test-output-sanitize.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/prompt-overrides.sh"
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_TEST_ASSESSMENT_ROOT/scripts/lib/acceptance-block.sh"

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
        "$state_dir" \
        "$artifact_dir/design.md"
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
#   $9 = design.md path (optional; acceptance-block consumed when present, ADR-031)
_test_assessment_run_inner() {
    local scope_manifest="$1"
    local test_results_path="$2"
    local plan_path="$3"
    local build_summary_path="$4"
    local output_json="$5"
    local output_md="$6"
    local artifact_dir="${7:-$(dirname "$output_json")}"
    local state_dir="${8:-$(dirname "$artifact_dir")}"
    local design_md="${9:-}"

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

    # ─── Acceptance-block (ADR-031) ──────────────────────────────────────────
    local -a _ab_specs=() _ab_testfiles=() _ab_missing=()
    local _ab_present=0
    if [[ -n "$design_md" && -f "$design_md" ]]; then
        local _ab_raw
        if _ab_raw="$(extract_acceptance_block "$design_md" 2>/dev/null)"; then
            _ab_present=1
            local _ab_in_tf=0
            while IFS= read -r _ab_line; do
                if [[ "$_ab_line" == "TESTFILES:" ]]; then
                    _ab_in_tf=1
                elif [[ $_ab_in_tf -eq 1 && -n "$_ab_line" ]]; then
                    _ab_line="${_ab_line%$'\r'}"   # tolerate a CRLF design.md
                    [[ -z "$_ab_line" ]] && continue
                    # ADR-031: TESTFILES are repo-relative and grant no scope.
                    # Reject absolute / ".."-containing paths from the LLM-produced
                    # design.md, fail-closed (mirrors the design + build guards) so
                    # the gate can never reference a file outside the repo.
                    if [[ "$_ab_line" == /* || "/$_ab_line/" == *"/../"* ]]; then
                        _ab_missing+=("$_ab_line")
                        continue
                    fi
                    _ab_testfiles+=("$_ab_line")
                elif [[ "$_ab_line" == SPEC:* ]]; then
                    _ab_specs+=("$_ab_line")
                fi
            done <<< "$_ab_raw"
            # Deterministic TESTFILES existence gate (pre-LLM, no token spend)
            local _tf
            for _tf in "${_ab_testfiles[@]+"${_ab_testfiles[@]}"}"; do
                [[ -f "$_tf" ]] || _ab_missing+=("$_tf")
            done
        fi
    fi
    if [[ ${#_ab_missing[@]} -gt 0 ]]; then
        local _miss_str; _miss_str="$(printf ' %s' "${_ab_missing[@]}")"
        emit_event "test_assessment.acceptance_fail" \
            "plugin=test_assessment" "reason=acceptance_not_verified" \
            "missing=${_miss_str# }" 2>/dev/null || true
        _test_assessment_write_acceptance_fail \
            "$output_json" "$output_md" "$state_dir" \
            "acceptance-block TESTFILES missing:${_miss_str}"
        return 0
    fi

    # #824: use intake-captured baseline sha so cumulative branch numstat
    # reflects ALL work since cycle start, including UNCOMMITTED worktree
    # changes (which build's per-iter diff.patch artifact misses on timeout
    # paths). Fail-closed if baseline missing — silent fallback to the old
    # `branch_numstat` would re-introduce the dogfood loop bug.
    local _baseline_ref_file="$state_dir/intake-baseline-ref.txt"
    local _baseline_sha=""
    if [[ -f "$_baseline_ref_file" ]]; then
        _baseline_sha="$(head -1 "$_baseline_ref_file" | tr -d '[:space:]')"
    fi
    local numstat
    if [[ -z "$_baseline_sha" ]]; then
        error "_test_assessment_run_inner: intake-baseline-ref.txt missing at $_baseline_ref_file — fail-CLOSED"
        emit_event "test_assessment.missing_baseline" "plugin=test_assessment" \
            "path=$_baseline_ref_file"
        return 2
    fi
    numstat="$(branch_numstat_since "$_baseline_sha" 2>/dev/null || echo unknown)"
    [[ -z "$numstat" ]] && numstat="unknown"

    # Compute worktree durability: dirty means uncommitted changes are present
    # (scope-violation edits about to be reverted — files on disk are transient).
    local _wt_dirty_count
    _wt_dirty_count="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
    local worktree_status="clean"
    [[ "${_wt_dirty_count:-0}" -gt 0 ]] && worktree_status="dirty"

    # Truncate test_output (keep tail).
    local output_bytes="$ZBUILD_TEST_ASSESSMENT_OUTPUT_BYTES"
    if [[ ${#test_output} -gt $output_bytes ]]; then
        test_output="…[truncated head]…${test_output: -$output_bytes}"
    fi

    # Render plan + assembly of human-readable context.
    local plan_md
    plan_md="$(render_artifact plan "$plan_content" 2>/dev/null || printf '%s' "$plan_content")"

    # ─── Compose prompt ──────────────────────────────────────────────────────
    # ADR-028: canonical OUTPUT CONTRACT block from framework. ADR-022 v2:
    # failure_summary_md is a markdown free-text field (escape required).
    # ADR-031: acceptance_verified added when acceptance block is present.
    local _av_schema_field=""
    [[ $_ab_present -eq 1 ]] && _av_schema_field=$'    "acceptance_verified": true | false,\n'
    local _ta_schema
    _ta_schema='  {
    "schema_version": 1,
    "verdict": "pass" | "fail" | "error" | "inconclusive",
    "summary": "<one-paragraph synthesis>",
    "diagnosis": "<root-cause analysis if not pass; empty string if pass>",
    "required_changes": ["<actionable change>", "..."],
    "agrees_with_build_complete": true | false,
    "branch_numstat": "<verbatim from input>",
'"${_av_schema_field}"'    "failure_summary_md": "<markdown report fed back to the build stage>",
    "iter": <integer>
  }'
    local _output_contract_block
    _output_contract_block="$(_llm_output_contract \
        --stage test_assessment \
        --verdicts "pass,fail,error,inconclusive" \
        --schema-json "$_ta_schema" \
        --markdown-fields "failure_summary_md")"

    # Static heredoc — no expansion. The remaining body explains semantics +
    # tool-use; the OUTPUT CONTRACT/schema are prepended from the framework.
    local _ta_instructions
    _ta_instructions="$(cat <<'TA_PROMPT'
You are a test-results assessment agent. Examine the test output in light of
the plan and the build claim, then produce a structured JSON verdict.

Tool use:
- You may use the Read tool to inspect files referenced in the plan or in the
  test output. Do NOT call Edit, Write, or Bash. This stage is read-only.

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

## Verification discipline (#824)

The BUILD CLAIM and BRANCH NUMSTAT fields above are DERIVED signals. They
can be stale or misclassified — for example, build's scope_violation
handling on timeout writes verdict=scope_violation even when the worktree
has real implementation files from mid-iteration Edit/Write calls.

Before returning verdict=fail or verdict=inconclusive based on "no work
visible in numstat", you MUST spot-check the actual repo state using the
Read tool against the plan's files[] entries.

- If the artifacts named in the plan exist on disk and match the plan's
  intent, return verdict=pass EVEN IF the per-iter diff is 0/0/0 — that
  means the cycle has already converged and the build agent is correctly
  emitting LOOP_COMPLETE on a no-op.
- Only return fail/inconclusive if a spot-check confirms the deliverables
  are actually missing or wrong.

The Read tool is granted for exactly this purpose. Failing to use it when
the BUILD CLAIM and BRANCH NUMSTAT disagree with what tests pass is a
contract violation that produces the build_test_cycle infinite loop
documented in #824.

## Pass guard for dirty worktree (#847)

When WORKTREE STATUS is dirty the repo contains uncommitted changes that are
about to be reverted (scope-violation edits). Files visible on disk via Read
are transient — they may disappear before the next test run.

Hard guard: if WORKTREE STATUS is dirty AND TEST SUMMARY verdict is NOT
pass (fail, error, or unknown), you MUST return verdict=inconclusive. Do
NOT return pass based on Read spot-checks when the worktree is dirty and
the tests did not pass — the files you read may not survive the pending
revert.

Only upgrade to pass when WORKTREE STATUS is clean OR TEST SUMMARY
verdict is already pass.

TA_PROMPT
)"
    _ta_instructions="$_output_contract_block

$_ta_instructions"

    # Build acceptance-block prompt section when present (ADR-031)
    local _ab_prompt=""
    if [[ $_ab_present -eq 1 ]]; then
        _ab_prompt=$'\n\nACCEPTANCE CRITERIA (from design.md):\n'
        local _s
        for _s in "${_ab_specs[@]+"${_ab_specs[@]}"}"; do
            _ab_prompt+="$_s"$'\n'
        done
        if [[ ${#_ab_testfiles[@]} -gt 0 ]]; then
            _ab_prompt+=$'TESTFILES:\n'
            local _tf2
            for _tf2 in "${_ab_testfiles[@]}"; do
                _ab_prompt+="$_tf2"$'\n'
            done
        fi
        _ab_prompt+=$'\nSet acceptance_verified=true ONLY when every SPEC claim is grounded in passing test output AND all TESTFILES are present and passing.\n'
    fi

    local prompt
    printf -v prompt '%s\n\nPLAN:\n%s\n\nBUILD CLAIM:\n verdict=%s iterations=%s terminated_reason=%s\n\nBRANCH NUMSTAT:\n%s\n\nWORKTREE STATUS:\n%s\n\nTEST SUMMARY:\n verdict=%s passed=%s failed=%s\n\nTEST OUTPUT (verbatim, possibly truncated):\n%s\n' \
        "$_ta_instructions" \
        "$plan_md" \
        "$build_verdict" "$build_iters" "$build_term" \
        "$numstat" \
        "$worktree_status" \
        "$test_verdict" "$test_passed" "$test_failed" \
        "$test_output"
    [[ -n "$_ab_prompt" ]] && prompt+="$_ab_prompt"

    # ─── Redaction chokepoint (ADR-004, required) ────────────────────────────
    local prompt_file="$artifact_dir/test-assessment-prompt.txt"
    printf '%s\n' "$prompt" > "$prompt_file"
    # ADR-032 (#855): per-repo override appended AFTER the contract, BEFORE
    # redaction (so it is redaction-covered and cannot weaken the charter).
    append_prompt_override "$prompt_file" "test_assessment"
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
    # When acceptance block present, require acceptance_verified boolean (ADR-031)
    [[ $_ab_present -eq 1 ]] && \
        schema_expr="$schema_expr and (.acceptance_verified | type==\"boolean\")"
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
    local worktree_not_durable=0
    if [[ "$llm_verdict" == "pass" ]]; then
        local ok=1
        # test.failed must be 0
        if [[ "$test_failed" =~ ^[0-9]+$ ]]; then
            (( test_failed != 0 )) && ok=0
        fi
        # (a) test_verdict from test-results.json must be pass — catches
        # zero-count but non-zero exit scenarios (e.g. verdict=fail, failed=0).
        [[ "$test_verdict" != "pass" ]] && ok=0
        # When build_verdict=empty_diff, the LLM may return agrees_with_build_complete=false
        # because it cannot interpret "empty_diff" as a successful build completion.
        # Objective evidence (test_verdict=pass, test_failed=0, clean worktree) is
        # conclusive; the LLM's subjective agreement must not veto it for empty_diff.
        if [[ "$build_verdict" != "empty_diff" ]]; then
            [[ "$llm_agrees" != "true" ]] && ok=0
        fi
        # #895: accept the convergence-eligible build-verdict allowlist
        # (pass | empty_diff), not pass-only. empty_diff = build found the work
        # already done; a green suite on it is real convergence, not a livelock.
        _ta_build_verdict_convergeable "$build_verdict" || ok=0
        # #895: an empty_diff that left a DIRTY worktree is not durable — build
        # claimed no changes yet files are uncommitted on disk. Reject so we do
        # not converge over transient state (the #847 guard below only fires
        # when test_verdict != pass).
        if [[ "$build_verdict" == "empty_diff" && "$worktree_status" == "dirty" ]]; then
            ok=0
            worktree_not_durable=1
        fi
        # (b) dirty worktree + non-pass test_verdict = not durable; files on
        # disk are transient scope-violation edits about to be reverted.
        if [[ "$worktree_status" == "dirty" && "$test_verdict" != "pass" ]]; then
            ok=0
            worktree_not_durable=1
        fi
        if [[ $ok -eq 0 ]]; then
            final_verdict="inconclusive"
            downgraded=1
            local _downgrade_reason="build_test_disagreement"
            [[ $worktree_not_durable -eq 1 ]] && _downgrade_reason="worktree_not_durable"
            emit_event "test_assessment.downgrade" \
                "plugin=test_assessment" \
                "from=pass" \
                "to=inconclusive" \
                "reason=$_downgrade_reason" \
                "test_failed=$test_failed" \
                "test_verdict=$test_verdict" \
                "worktree_status=$worktree_status" \
                "build_verdict=$build_verdict" \
                "agrees=$llm_agrees"
        fi
    fi

    # ─── Acceptance-block downgrade (ADR-031) ────────────────────────────────
    # Only fires when block is present AND verdict is still pass after above.
    local _ab_llm_rejected=0
    if [[ $_ab_present -eq 1 && "$final_verdict" == "pass" ]]; then
        local _llm_av
        _llm_av="$(printf '%s' "$stripped" | jq -r '.acceptance_verified // "false"' 2>/dev/null || echo "false")"
        if [[ "$_llm_av" != "true" ]]; then
            final_verdict="fail"
            downgraded=1
            _ab_llm_rejected=1
            emit_event "test_assessment.downgrade" \
                "plugin=test_assessment" \
                "from=pass" "to=fail" \
                "reason=acceptance_llm_rejected" \
                "acceptance_verified=$_llm_av"
        fi
    fi

    # Rewrite verdict + (when downgraded) append a required_changes note,
    # then ensure branch_numstat is the helper's verbatim line. failure_summary_md
    # is preserved as the LLM emitted it (the build feedback body).
    local downgrade_note=""
    if [[ $downgraded -eq 1 ]]; then
        if [[ $_ab_llm_rejected -eq 1 ]]; then
            downgrade_note="verdict downgraded to fail: acceptance criteria not verified (acceptance_verified=false in LLM response)"
        elif [[ $worktree_not_durable -eq 1 ]]; then
            downgrade_note="verdict downgraded: worktree dirty — uncommitted changes are transient (about to be reverted), not durable for convergence (test_verdict=$test_verdict build_verdict=$build_verdict)"
        else
            downgrade_note="verdict downgraded: build/test disagreement (test_failed=$test_failed test_verdict=$test_verdict agrees=$llm_agrees build_verdict=$build_verdict)"
        fi
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

# ─── pre-LLM acceptance fail writer (ADR-031) ───────────────────────────────
# Writes test-assessment.json with verdict=fail when TESTFILES are missing.
# Args: $1=output_json $2=output_md $3=state_dir $4=detail
_test_assessment_write_acceptance_fail() {
    local output_json="$1" output_md="$2" state_dir="$3" detail="$4"
    local final_json
    final_json="$(jq -nc \
        --arg detail "$detail" \
        '{schema_version:1, verdict:"fail", reason:"acceptance_not_verified",
          summary:$detail, diagnosis:$detail, required_changes:[],
          agrees_with_build_complete:false, branch_numstat:"unknown",
          acceptance_verified:false,
          failure_summary_md:("Acceptance check failed: " + $detail), iter:0}')"
    local rendered_md
    rendered_md="$(render_test_assessment_md "$final_json" 2>/dev/null || \
        printf '# Test Assessment: fail\n\n%s\n' "$detail")"
    printf '%s\n' "$final_json" | atomic_write "$output_json"
    printf '%s\n' "$rendered_md" | atomic_write "$output_md"
    if [[ -n "${ZBUILD_CYCLE_ID:-}" && -n "${ZBUILD_CYCLE_ITER:-}" ]]; then
        local iter_dir="$state_dir/cycle-${ZBUILD_CYCLE_ID}/iter-${ZBUILD_CYCLE_ITER}"
        mkdir -p "$iter_dir"
        printf '%s\n' "$final_json"  | atomic_write "$iter_dir/test-assessment.json"
        printf '%s\n' "$rendered_md" | atomic_write "$iter_dir/test-assessment.md"
    fi
    emit_event "plugin.run.complete" "stage=test_assessment" \
        "plugin=test_assessment" "verdict=fail" \
        "reason=acceptance_not_verified" "artifact=test-assessment.json" 2>/dev/null || true
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
