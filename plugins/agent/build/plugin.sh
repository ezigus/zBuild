#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/build — Build stage agent (issues #341, #467)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: build (ADR-013 T2, ADR-018 Pattern 2 — agent-loop with derived diff)
# Produces: state/artifacts/diff.patch AND state/artifacts/build-summary.json
#
# Lifecycle:
#   build_stage_run         — derive paths, delegate to _build_stage_run_inner
#   _build_stage_run_inner  — redact → route_to_model_loop → git diff → write
#   build_stage_cleanup     — no-op (the engine brackets the hook, #1705)
#
# CRITICAL: diff.patch is NEVER applied here — it is the working-tree diff
# left by the agent loop, captured via `git diff HEAD` after the loop returns.
# The downstream test stage applies and validates it.

[[ -n "${_ZBUILD_BUILD_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_BUILD_DIR="$_ZBUILD_PLUGIN_DIR"
_BUILD_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_BUILD_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_BUILD_ROOT/core/router/route.sh"
# #498: stage_io_begin/end emit the post-loop changed-files summary banner.
# route.sh already sources stage-io, but make the dependency explicit so
# unit tests that load only the plugin (not the router) still get it.
# shellcheck source=../../../core/output/stage-io.sh
source "$_BUILD_ROOT/core/output/stage-io.sh"
# ADR-018 (#470): artifact renderer registry for inter-stage markdown.
# shellcheck source=../../../scripts/lib/artifact-render.sh
source "$_BUILD_ROOT/scripts/lib/artifact-render.sh"
# #506: shared numstat banner formatter (also used by review).
# shellcheck source=../../../scripts/lib/numstat-format.sh
source "$_BUILD_ROOT/scripts/lib/numstat-format.sh"
# shellcheck source=../../../scripts/lib/prompt-overrides.sh
source "$_BUILD_ROOT/scripts/lib/prompt-overrides.sh"
# ADR-031 (#866): acceptance-block extractor for charter injection into prompt.
# shellcheck source=../../../scripts/lib/acceptance-block.sh
source "$_BUILD_ROOT/scripts/lib/acceptance-block.sh"
# #721: strip stage-io banners and ANSI from feedback text before LLM prompt.
# shellcheck source=../../../scripts/lib/test-output-sanitize.sh
source "$_BUILD_ROOT/scripts/lib/test-output-sanitize.sh"
# ADR-050 (#1581): unified prior-work seam — read a prior run's build-summary.json.
# shellcheck source=../../../scripts/lib/prior-output-reader.sh
source "$_BUILD_ROOT/scripts/lib/prior-output-reader.sh"

# ─── lib modules (decomposed from this file per #1533) ───────────────────────
# shellcheck source=lib/context.sh
source "$_BUILD_DIR/lib/context.sh"
# shellcheck source=lib/diff.sh
source "$_BUILD_DIR/lib/diff.sh"
# shellcheck source=lib/prompt.sh
source "$_BUILD_DIR/lib/prompt.sh"
# shellcheck source=lib/scope.sh
source "$_BUILD_DIR/lib/scope.sh"
# shellcheck source=lib/commit.sh
source "$_BUILD_DIR/lib/commit.sh"
# shellcheck source=lib/summary.sh
source "$_BUILD_DIR/lib/summary.sh"

# ─── run ────────────────────────────────────────────────────────────────────
build_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "build_stage_run: state_file argument required"
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/build-summary.md}" "build" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    local plan_json_path="$artifacts_dir/plan.json"

    _build_stage_run_inner \
        "$scope_manifest" \
        "$plan_json_path" \
        "$artifacts_dir/diff.patch" \
        "$artifacts_dir/build-summary.json" \
        "$artifacts_dir"
}

# Inner implementation — unit-testable with explicit paths.
# Args:
#   $1 = scope_manifest path
#   $2 = plan_json_path
#   $3 = output_diff_patch path
#   $4 = output_summary_json path
#   $5 = artifact_dir for intermediate files
_build_stage_run_inner() {
    local scope_manifest="$1"
    local plan_json_path="$2"
    local output_diff_patch="$3"
    local output_summary_json="$4"
    local artifact_dir="${5:-$(dirname "$output_summary_json")}"

    if [[ -z "$scope_manifest" || -z "$plan_json_path" || -z "$output_diff_patch" || -z "$output_summary_json" ]]; then
        error "_build_stage_run_inner: requires <scope_manifest> <plan_json_path> <output_diff_patch> <output_summary_json> [artifact_dir]"
        return 2
    fi

    mkdir -p "$artifact_dir"

    if [[ ! -f "$plan_json_path" ]]; then
        error "_build_stage_run_inner: plan.json not found at $plan_json_path"
        stage_summary_write "$artifact_dir/build-summary.md" "build" "error" \
            "no plan.json to build from" \
            "The plan stage produced nothing to implement; no code was written."
        emit_event "plugin.result" "verdict=error" "plugin=build" "reason=missing_plan_json"
        return 2
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    local plan_files_csv="" _acceptance_testfiles="" _acceptance_spec_ids="" _design_decisions=""
    _build_load_context

    # ─── Write build prompt (ADR-018 Pattern 2, #571 v2 framing) ─────────────
    # Three-section framed structure the LLM sees on every iteration:
    #   1. ORIGINAL TASK (immutable across iterations) — issue goal + plan md
    #   2. INSTRUCTIONS — scope/loop/sentinel rules (stable across iters)
    #   3. CURRENT ITERATION FEEDBACK — empty on iter 1; iter 2+: prior
    #      test_assessment markdown (wired by #568 via cycle feedback dir).
    local prompt_input_file="$artifact_dir/build-prompt.txt"

    # ADR-018 (#470): render plan.json as markdown for LLM consumption when
    # the renderer registry is available. Falls back to raw JSON otherwise.
    local plan_payload="$plan_json"
    if declare -F render_artifact >/dev/null 2>&1; then
        plan_payload="$(render_artifact plan "$plan_json" 2>/dev/null || echo "$plan_json")"
    fi

    # Resolve banner iter/max — iter from cycle context (defaults to 1),
    # max from router resolver. Banner is operator-visible after #566.
    local _iter_n="${ZBUILD_CYCLE_ITER:-1}"
    local _iter_max
    _iter_max="$(_route_resolve_max_iterations 2>/dev/null || echo 10)"
    [[ "$_iter_max" =~ ^[0-9]+$ ]] || _iter_max=10

    local _task_header
    _task_header="$(_build_render_task_header "$_iter_n" "$_iter_max")"

    local _build_instructions
    _build_instructions="$(_build_compose_instructions "$plan_files_csv")"
    # _BUILD_PERSONA_APPLIED is set inside _build_compose_instructions but runs in a
    # subshell via $() — it cannot propagate here. Re-probe persona status directly,
    # mirroring the SAME empty-output guard the composer uses: persona counts as
    # applied only when persona_stage_framing exits 0 AND yields non-empty perspective
    # (rc=0-but-empty → the composer falls back, so telemetry must too).
    local _build_persona_applied=0 _persona_probe
    if _persona_probe="$(persona_stage_framing developer "" "$_BUILD_ROOT/plugins" 2>/dev/null)" \
       && [[ -n "${_persona_probe//[[:space:]]/}" ]]; then
        _build_persona_applied=1
    fi

    # Iter 2+: pull prior test_assessment markdown. Empty when no cycle or
    # file missing/empty (silent-failure guard — see _build_read_prior_assessment).
    local _feedback_body
    _feedback_body="$(_build_read_prior_assessment 2>/dev/null || true)"
    # #721: strip stage-io banners, ANSI codes, and OOS-marker tags before
    # splicing into the prompt — prior_test_assessment.txt is captured
    # pipeline output and is the primary noise vector for this stage.
    [[ -n "$_feedback_body" ]] && \
        _feedback_body="$(printf '%s' "$_feedback_body" | _zbuild_sanitize_for_llm)"

    # ADR-026 / Wave 18-B (#707): outer-cycle review-remediation feedback.
    # Empty when not running inside build_review_cycle, when the feedback dir is
    # not exported, or when the file is missing/empty (silent-failure guard,
    # see _build_read_prior_review). Independent of prior_test_assessment —
    # both can co-exist when build runs as a member of build_test_cycle
    # nested inside build_review_cycle (review feedback drove the outer iter,
    # test_assessment feedback drove the inner iter).
    local _review_feedback_body
    _review_feedback_body="$(_build_read_prior_review 2>/dev/null || true)"
    # #721: sanitize review feedback — prior_review_feedback.txt originates
    # from the review stage's stage-io machinery and may carry banner lines.
    [[ -n "$_review_feedback_body" ]] && \
        _review_feedback_body="$(printf '%s' "$_review_feedback_body" | _zbuild_sanitize_for_llm)"
    # #951 Layer 2: structured acceptance-coverage gaps (untagged SPEC ids) from
    # the prior outer iter's acceptance-gate. Advisory + re-verify against the
    # current tree; authoritative over review prose on acceptance matters.
    local _acceptance_gap_ids
    _acceptance_gap_ids="$(_build_read_prior_acceptance 2>/dev/null || true)"

    # #1583: tautological [change] SPECs (assertion passes at baseline) the gate
    # flagged — build OWNS these assertion bodies (#1477) and must re-author them
    # to fail-at-baseline. Explicitly re-authorable (the negative control polices it).
    local _acceptance_tautology_ids
    _acceptance_tautology_ids="$(_build_read_tautology_ids 2>/dev/null || true)"

    _build_compose_prompt_body "$prompt_input_file" "$_task_header" "$plan_payload" \
        "$_build_instructions" "$_design_decisions" "$_acceptance_testfiles" \
        "$_acceptance_spec_ids" "$_review_feedback_body" "$_acceptance_gap_ids" \
        "$_feedback_body" "$_iter_n" \
        "$_acceptance_tautology_ids"

    # ADR-050 (#1581): cross-run seed — when a prior RUN of this issue produced a
    # build-summary (restored onto this runner), append a short advisory note so
    # build continues the prior attempt rather than restarting. Appended AFTER the
    # composed body (mirrors design's prior-work injection). Sanitized like the
    # other feedback bodies before it reaches the prompt.
    local _prior_build_note
    _prior_build_note="$(_build_read_prior_build_summary 2>/dev/null || true)"
    if [[ -n "$_prior_build_note" ]]; then
        _prior_build_note="$(printf '%s' "$_prior_build_note" | _zbuild_sanitize_for_llm)"
        printf '\n## PRIOR BUILD (a previous attempt on this issue — continue, do not restart)\n%s\n' \
            "$_prior_build_note" >> "$prompt_input_file"
    fi

    # ADR-032 (#855): per-repo override appended AFTER the contract (so the
    # operator overlay can never precede or weaken the shipped charter). ADR-043:
    # redaction is owned by the router — route_to_model_loop redacts each
    # iteration's prompt (this override included) by construction, using the
    # runner-exported ZBUILD_SCOPE_MANIFEST + the --scope-allowlist passed below
    # (#606: plan.files[] keeps in-scope paths out of the OOS wrap).
    append_prompt_override "$prompt_input_file" "build"

    # ─── Route through agent loop (ADR-018 Pattern 2) ────────────────────────
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier; tier="$(resolve_tier build "$_BUILD_DIR")" || return 1
    local max_iter; max_iter="$(_route_resolve_max_iterations 2>/dev/null || echo 10)"
    [[ "$max_iter" =~ ^[0-9]+$ ]] || max_iter=10
    # ─── #511 F2: cycle-budget clamp ─────────────────────────────────────────
    # When running INSIDE a cycle iter (ZBUILD_CYCLE_ITER set by orchestrator),
    # clamp the inner agent-loop max_iterations to 15 to bound worst-case cost
    # (cycle.max_iter × stage_count × inner.max_iter). Default upper bound is
    # 25 (per ADR-018), so we cap to 15 only when it would exceed.
    if [[ -n "${ZBUILD_CYCLE_ITER:-}" && "$max_iter" -gt 15 ]]; then
        local _orig="$max_iter"
        max_iter=15
        emit_event "build.cycle.max_turns_clamped" "plugin=build" \
            "iter=${ZBUILD_CYCLE_ITER}" "orig=$_orig" "clamped=$max_iter" \
            >/dev/null 2>&1 || true
    fi

    local router_rc=0
    local _prev_persona_env="${ZBUILD_STAGE_IO_PERSONA-__UNSET__}"
    if [[ "$_build_persona_applied" -eq 1 ]]; then
        export ZBUILD_STAGE_IO_PERSONA=developer
    else
        export ZBUILD_STAGE_IO_PERSONA=developer:fallback
    fi
    # #491: do NOT redirect route_to_model_loop's stderr — the per-iteration
    # stage-io input banner writes to fd 2 (ZBUILD_STAGE_IO_FD default) and
    # 2>/dev/null would swallow every iteration's input banner, breaking the
    # ADR-015 §v4 input-before-action ordering contract for Pattern 2.
    # #646: --defer-final-banner-close keeps the final iter's stage-io banner
    # open across post-loop bookkeeping (numstat, scope check, discrepancy
    # warn) so the operator-visible warn lands INSIDE the banner pair instead
    # of leaking into the inter-stage gap. We flush the deferred close via
    # _route_loop_close_final_banner after _build_emit_changed_files_summary
    # below (or unconditionally on the early-exit paths).
    route_to_model_loop "$tier" "$prompt_input_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" \
        --defer-final-banner-close || router_rc=$?
    if [[ "$_prev_persona_env" == "__UNSET__" ]]; then
        unset ZBUILD_STAGE_IO_PERSONA
    else
        export ZBUILD_STAGE_IO_PERSONA="$_prev_persona_env"
    fi

    local iterations="${_ROUTE_LOOP_ITERATIONS:-0}"
    local terminated_reason="${_ROUTE_LOOP_TERMINATED_REASON:-error}"
    local loop_input_tokens="${_ROUTE_LOOP_INPUT_TOKENS:-0}"
    local loop_output_tokens="${_ROUTE_LOOP_OUTPUT_TOKENS:-0}"

    if [[ $router_rc -ge 2 ]]; then
        warn "_build_stage_run_inner: route_to_model_loop rc=$router_rc — writing empty diff and summary"
        terminated_reason="error"
    fi

    # #612: rc=130 from the router is a SIGINT propagation, not a build failure.
    # Skip the post-loop bookkeeping (diff capture, scope validation, summary
    # write, per-iter commit) and bubble 130 up so the cycle/runner sees it as
    # a terminal abort rather than continuing into the next stage/iter.
    # The router has already emitted loop.terminated.signal and cleared its
    # traps; we just need to short-circuit and propagate.
    if [[ $router_rc -eq 130 ]]; then
        warn "_build_stage_run_inner: route_to_model_loop rc=130 (SIGINT) — propagating abort"
        emit_event "build.aborted" "plugin=build" \
            "reason=sigint" "iterations=$iterations" >/dev/null 2>&1 || true
        # Best-effort: clear `git add -N` intent-to-add entries so a downstream
        # `git diff HEAD` after the abort sees a clean index.
        git -C "$repo_root" reset -q 2>/dev/null || true
        # #646: flush any deferred final-banner close so we don't orphan a
        # half-open banner pair into the EXIT trap. No-op when not deferred.
        if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
            _route_loop_close_final_banner || true
        fi
        return 130
    fi

    # ─── Derive diff.patch from git working tree ─────────────────────────────────
    _build_harvest_diff "$repo_root" "$output_diff_patch" "$artifact_dir"
    local diff_content="$_BUILD_HARVEST_DIFF_CONTENT"
    local _preexist_untracked="$_BUILD_HARVEST_PREEXIST_UNTRACKED"
    local _diff_failure="$_BUILD_HARVEST_DIFF_FAILURE"

    # ─── Scope post-validation via git diff --name-status -z ─────────────────────
    _build_validate_scope_violations "$diff_content" "$plan_files_csv" "$repo_root" \
        "$artifact_dir" "$output_diff_patch" "$router_rc" "$_preexist_untracked"
    local scope_violation="$_BUILD_VSCP_VIOLATION"
    diff_content="$_BUILD_VSCP_DIFF_CONTENT"
    local pre_zero_numstat="$_BUILD_VSCP_PRE_ZERO_NUMSTAT"
    local -a scope_violations=() scope_violations_created=()
    local _p
    while IFS= read -r _p; do [[ -n "$_p" ]] && scope_violations+=("$_p"); done \
        <<< "$_BUILD_VSCP_VIOLATIONS_NL"
    while IFS= read -r _p; do [[ -n "$_p" ]] && scope_violations_created+=("$_p"); done \
        <<< "$_BUILD_VSCP_VIOLATIONS_CREATED_NL"

    # Empty-diff signal: emit warn event when prose-only / no edits produced.
    if [[ -z "$diff_content" && "$scope_violation" != "true" && $router_rc -lt 2 ]]; then
        emit_event "build.empty_diff" "plugin=build" \
            "iterations=$iterations" "terminated_reason=$terminated_reason"
    fi

    # NB (#530): diff.patch was written directly from `git diff HEAD` above
    # to preserve the trailing newline. We do NOT re-write it from
    # `$diff_content` here — that would re-introduce the bash command-
    # substitution trailing-newline strip.

    # ─── Parse diff stats ────────────────────────────────────────────────────
    local files_changed_json="[]" lines_added=0 lines_removed=0
    if [[ -n "$diff_content" ]]; then
        local changed_files_raw
        changed_files_raw="$(printf '%s' "$diff_content" \
            | grep '^diff --git' \
            | sed 's|^diff --git a/[^ ]* b/||' || true)"
        if [[ -n "$changed_files_raw" ]]; then
            files_changed_json="$(printf '%s\n' "$changed_files_raw" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
        fi
        lines_added="$(printf '%s' "$diff_content" | grep -c '^+' 2>/dev/null || true)"
        lines_removed="$(printf '%s' "$diff_content" | grep -c '^-' 2>/dev/null || true)"
        local header_plus header_minus
        header_plus="$(printf '%s' "$diff_content" | grep -c '^+++' 2>/dev/null || true)"
        header_minus="$(printf '%s' "$diff_content" | grep -c '^---' 2>/dev/null || true)"
        lines_added=$(( lines_added - header_plus ))
        lines_removed=$(( lines_removed - header_minus ))
        [[ $lines_added -lt 0 ]] && lines_added=0
        [[ $lines_removed -lt 0 ]] && lines_removed=0
    fi
    local files_changed_count
    files_changed_count="$(printf '%s' "$files_changed_json" | jq 'length' 2>/dev/null || echo 0)"

    # ─── Write build-summary.json ─────────────────────────────────────────────────
    local issue="${ZBUILD_ISSUE:-0}"; [[ "$issue" =~ ^[0-9]+$ ]] || issue=0
    # shellcheck disable=SC2034  # read by _build_write_build_summary via dynamic scope
    local loop_input_tokens="${_ROUTE_LOOP_INPUT_TOKENS:-0}"
    # shellcheck disable=SC2034  # read by _build_write_build_summary via dynamic scope
    local loop_output_tokens="${_ROUTE_LOOP_OUTPUT_TOKENS:-0}"
    local build_verdict=""
    _build_write_build_summary

    # ─── #587: post-loop discrepancy + numstat summary (no banner) ───────────
    # Originally (#498) this emitted a [computed] stage_io banner pair after
    # route_to_model_loop returned, so the operator saw both LLM prose (#482's
    # [llm] banners) AND what files actually changed on disk. #566 made the
    # [llm] banners more prominent, exposing the [computed] pair as redundant
    # duplication. #587 removed the banner entirely — the function now emits
    # `build.discrepancy.detected` + `build.diff.empty_after_done_sentinel`
    # events plus a single-line stderr `warn` instead.
    _BUILD_PLAN_FILES_CSV="$plan_files_csv" \
    _build_emit_changed_files_summary \
        "$repo_root" "$terminated_reason" \
        "$scope_violation" "$pre_zero_numstat" || true

    # #646: now that the discrepancy warn (if any) has fired, flush the
    # deferred close of the final LLM iter's stage-io banner. Safe no-op when
    # the loop didn't stash a deferred close (e.g., the exit path was not
    # done_sentinel). The warn lands inside the banner pair instead of in
    # the inter-stage gap.
    if declare -F _route_loop_close_final_banner >/dev/null 2>&1; then
        _route_loop_close_final_banner || true
    fi

    # ─── #608: per-iteration commit (pipeline owns commit semantics) ─────────
    # The build prompt promises the LLM does not commit; the pipeline does.
    # Without this, test_assessment reads numstat=0 against HEAD even when
    # the LLM did real work (PR #608). Skipped on scope_violation/empty_diff;
    # see _build_commit_iteration above.
    local _plan_title
    _plan_title="$(printf '%s' "$plan_json" | jq -r '.title // ""' 2>/dev/null || echo "")"
    # #1329: compose the commit message cumulatively from the per-iteration
    # COMMIT_SUMMARY values the router accumulated (_ROUTE_LOOP_ITER_SUMMARIES,
    # newline-separated) plus the inner-loop iteration count. LAST_RESPONSE is
    # still passed for the single-iteration / legacy-stub fallback path.
    _build_commit_iteration \
        "$repo_root" \
        "$plan_files_csv" \
        "$scope_violation" \
        "$build_verdict" \
        "${_ROUTE_LOOP_LAST_RESPONSE:-}" \
        "$_plan_title" \
        "$_iter_n" \
        "${_ROUTE_LOOP_ITER_SUMMARIES:-}" \
        "${_ROUTE_LOOP_ITERATIONS:-1}" || true

    # ─── #661 / ADR-020 amendment: cumulative baseline→HEAD rewrite ──────────────
    _build_rewrite_cumulative_diff "$scope_violation" "$artifact_dir" "$repo_root" \
        "$output_diff_patch" "$_diff_failure" || true

    stage_summary_write "$artifact_dir/build-summary.md" "build" "pass" \
        "changed $files_changed_count file(s) over $iterations iteration(s)" \
        "$(printf -- '- lines: +%s / -%s\n- terminated: %s\n- scope violation: %s' "$lines_added" "$lines_removed" "$terminated_reason" "$scope_violation")"
    emit_event "plugin.result" "stage=build" \
        "plugin=build" \
        "files_changed_count=$files_changed_count" \
        "lines_added=$lines_added" \
        "lines_removed=$lines_removed" \
        "iterations=$iterations" \
        "terminated_reason=$terminated_reason" \
        "scope_violation=$scope_violation" \
        "verdict=$build_verdict" \
        "artifact=build-summary.json"

    # #530: clear `git add -N` intent-to-add entries from the index now that
    # scope-validation has run + the diff has been written. Downstream
    # consumers (test stage rsync) see a clean index.
    git -C "$repo_root" reset -q 2>/dev/null || true

    # #602: no more fail-CLOSED rc-wins path — the apply-check gate that
    # forced rc=1 on `verdict=corrupt_diff` was removed with the stash dance.
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
build_stage_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second `complete` from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
