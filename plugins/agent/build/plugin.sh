#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/build — Build stage agent (issues #341, #467)              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: build (ADR-013 T2, ADR-018 Pattern 2 — agent-loop with derived diff)
# Produces: state/artifacts/diff.patch AND state/artifacts/build-summary.json
#
# Lifecycle:
#   build_stage_init        — set env vars, emit plugin.init.start
#   build_stage_run         — derive paths, delegate to _build_stage_run_inner
#   _build_stage_run_inner  — redact → route_to_model_loop → git diff → write
#   build_stage_finalize    — emit plugin.finalize.complete
#   build_stage_cleanup     — emit plugin.cleanup.complete
#
# CRITICAL: diff.patch is NEVER applied here — it is the working-tree diff
# left by the agent loop, captured via `git diff HEAD` after the loop returns.
# The downstream test stage applies and validates it.

[[ -n "${_ZBUILD_BUILD_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_BUILD_DIR="$_ZBUILD_PLUGIN_DIR"
_BUILD_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_BUILD_ROOT/core/redaction/scope-redaction.sh"
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

# ─── init ───────────────────────────────────────────────────────────────────
build_stage_init() {
    export ZBUILD_PLUGIN="build"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=build"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
build_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "build_stage_run: state_file argument required"
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
        emit_event "plugin.run.error" "plugin=build" "reason=missing_plan_json"
        return 2
    fi

    local plan_json
    plan_json="$(cat "$plan_json_path")"

    # Extract plan.files[] — the canonical scope for this build. Falls back to
    # plan.steps[].files[] for the legacy plan shape used by some fixtures.
    local plan_files_csv=""
    plan_files_csv="$(printf '%s' "$plan_json" | \
        jq -r '[(.files // []), ([.steps[]?.files[]?] // [])] | flatten | unique | join(",")' \
        2>/dev/null || echo "")"

    # #754: if design.md is present and contains a ```scope block, use it as the
    # authoritative scope source, overriding plan.json's files[].
    # legacy-citation: pipeline-stages.sh:38-71 (_extract_scope_from_design)
    local _design_md_path="$artifact_dir/design.md"
    if [[ ! -f "$_design_md_path" ]]; then
        local _state_dir_for_design; _state_dir_for_design="$(dirname "$artifact_dir")"
        local _candidate="$_state_dir_for_design/artifacts/design.md"
        [[ -f "$_candidate" ]] && _design_md_path="$_candidate"
    fi
    # ADR-031 (#866): extract acceptance test file paths from design.md for
    # charter injection. Captured here so _design_md_path is already resolved.
    local _acceptance_testfiles=""
    if [[ -f "$_design_md_path" ]]; then
        _acceptance_testfiles="$(_build_read_acceptance_testfiles "$_design_md_path" 2>/dev/null || true)"
    fi
    # #916 (ADR-020): the design.md DECISION PROSE, so build honors design's
    # narrative directives ("build must do X") — not only its scope/acceptance.
    local _design_decisions=""
    if [[ -f "$_design_md_path" ]]; then
        _design_decisions="$(_build_read_design_decisions "$_design_md_path" 2>/dev/null || true)"
    fi

    local _scope_source="plan"
    if [[ -f "$_design_md_path" ]] && grep -q '^```scope' "$_design_md_path" 2>/dev/null; then
        local _design_csv
        _design_csv="$(_extract_scope_from_design "$_design_md_path" 2>/dev/null || echo "")"
        if [[ -n "$_design_csv" ]]; then
            plan_files_csv="$_design_csv"
            _scope_source="design"
        fi
    fi
    if [[ "$_scope_source" == "design" ]]; then
        local _scope_file_count=0
        if [[ -n "$plan_files_csv" ]]; then
            _scope_file_count="$(printf '%s' "$plan_files_csv" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo 0)"
        fi
        emit_event "build.scope_injected" "plugin=build" \
            "source=$_scope_source" "file_count=$_scope_file_count" \
            >/dev/null 2>&1 || true
    fi

    # #840 (ADR-030): consume a scope grant the cycle orchestrator wrote after a
    # prior iter's scope_expansion_request was auto-granted. Each granted path
    # becomes in-scope for THIS iter, so build can finally edit the collateral
    # file (e.g. the test pinning the old value) it was blocked on.
    if [[ -n "${ZBUILD_SCOPE_EXPANSION_GRANT:-}" && -f "$ZBUILD_SCOPE_EXPANSION_GRANT" ]]; then
        local _granted
        while IFS= read -r _granted; do
            [[ -z "$_granted" ]] && continue
            case ",$plan_files_csv," in
                *",$_granted,"*) ;;  # already in scope
                *) plan_files_csv="${plan_files_csv:+$plan_files_csv,}$_granted" ;;
            esac
        done < "$ZBUILD_SCOPE_EXPANSION_GRANT"
        emit_event "build.scope_grant_applied" "plugin=build" \
            "grant_file=$ZBUILD_SCOPE_EXPANSION_GRANT" >/dev/null 2>&1 || true
    fi

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

    # Iter 2+: pull prior test_assessment markdown. Empty when no cycle or
    # file missing/empty (silent-failure guard — see _build_read_prior_assessment).
    local _feedback_body
    _feedback_body="$(_build_read_prior_assessment 2>/dev/null || true)"

    # ADR-026 / Wave 18-B (#707): outer-cycle review-remediation feedback.
    # Empty when not running inside review_cycle, when the feedback dir is
    # not exported, or when the file is missing/empty (silent-failure guard,
    # see _build_read_prior_review). Independent of prior_test_assessment —
    # both can co-exist when build runs as a member of build_test_cycle
    # nested inside review_cycle (review feedback drove the outer iter,
    # test_assessment feedback drove the inner iter).
    local _review_feedback_body
    _review_feedback_body="$(_build_read_prior_review 2>/dev/null || true)"

    {
        printf '%s\n' "$_task_header"
        printf '## ORIGINAL TASK (immutable across iterations)\n'
        printf '%s\n\n' "$plan_payload"
        printf '## INSTRUCTIONS\n%s\n' "$_build_instructions"
        if [[ -n "$_design_decisions" ]]; then
            printf '\n## DESIGN DECISIONS (from the design stage — honor these directives; they refine the plan)\n'
            printf '%s\n' "$_design_decisions"
            printf 'Where a design decision above conflicts with the plan, follow the design decision.\n'
        fi
        if [[ -n "$_acceptance_testfiles" ]]; then
            printf '\n## ACCEPTANCE TESTS (you MUST make these pass — you MUST NOT weaken, modify assertions of, or delete them)\n'
            local _at_tf
            while IFS= read -r _at_tf; do
                [[ -n "$_at_tf" ]] && printf -- '- %s\n' "$_at_tf"
            done <<< "$_acceptance_testfiles"
        fi
        if [[ -n "$_review_feedback_body" ]]; then
            printf '\n## PRIOR REVIEW FEEDBACK (from a prior review iteration)\n'
            printf '%s\n' "$_review_feedback_body"
            printf 'Address the reviewer findings above before emitting LOOP_COMPLETE.\n'
        fi
        if [[ -n "$_feedback_body" ]]; then
            local _prev_iter=$(( _iter_n - 1 ))
            [[ "$_prev_iter" -lt 1 ]] && _prev_iter=1
            printf '\n## CURRENT ITERATION FEEDBACK (from test_assessment iter %d)\n' \
                "$_prev_iter"
            printf '%s\n' "$_feedback_body"
            printf 'Fix the issues above before emitting LOOP_COMPLETE.\n'
        fi
    } > "$prompt_input_file"

    # ADR-032 (#855): per-repo override appended AFTER the contract, BEFORE
    # redaction (so it is redaction-covered and cannot weaken the charter).
    append_prompt_override "$prompt_input_file" "build"

    local redacted_file="$artifact_dir/build-prompt.redacted.txt"

    # #606 Bug A1: pass the plan files CSV as the allowlist on the initial
    # redaction pass. Previously this was empty, so in-scope plan paths got
    # wrapped in <out-of-scope-context> before the agent loop ever saw them.
    if ! apply_scope_redaction "$prompt_input_file" "$redacted_file" "$scope_manifest" "$plan_files_csv" "0"; then
        error "_build_stage_run_inner: redaction failed; refusing to emit"
        emit_event "plugin.run.error" "plugin=build" "reason=redaction_failed"
        return 1
    fi

    # ─── Route through agent loop (ADR-018 Pattern 2) ────────────────────────
    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local tier="${ZBUILD_BUILD_TIER:-T2}"
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

    # Expose the scope manifest path so per-iteration redaction inside the loop
    # can satisfy C6 without inlining the manifest at every consumer.
    export ZBUILD_SCOPE_MANIFEST="$scope_manifest"

    local router_rc=0
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
    route_to_model_loop "$tier" "$redacted_file" "$repo_root" "$max_iter" \
        --scope-allowlist "$plan_files_csv" \
        --defer-final-banner-close || router_rc=$?

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

    # ─── Derive diff.patch from git working tree ─────────────────────────────
    # `git add -N` (intent-to-add) makes untracked files appear in `git diff HEAD`
    # without staging their content. Without it, new files created by the agent
    # would be silently dropped from the canonical diff.
    git -C "$repo_root" add -N . 2>/dev/null || true

    # #530: stream `git diff HEAD` DIRECTLY to the artifact file. Capturing via
    # `$()` strips the trailing newline (and `printf '%s'` doesn't restore it),
    # producing a 1-byte-truncated patch that downstream `git apply --check`
    # rejects ("corrupt patch at line N"). Writing to disk first sidesteps
    # bash's command-substitution byte stripping entirely.
    local diff_rc=0
    git -C "$repo_root" diff HEAD > "$output_diff_patch" 2>/dev/null || diff_rc=$?

    local _diff_failure="false"
    if [[ $diff_rc -ne 0 ]]; then
        warn "_build_stage_run_inner: git diff HEAD failed in $repo_root rc=$diff_rc"
        # NB: keep the existing `loop.git_diff_failed` event name (set by the
        # pre-#530 path and asserted by parity goldens) so callers don't need
        # to learn a new event. The new `build.git_diff_failed` was reserved
        # for force-fail semantics that we DO NOT enforce here — the apply-
        # check gate is the canonical fail-CLOSED point. See #530 PR notes.
        emit_event "loop.git_diff_failed" "plugin=build" \
            "cwd=$repo_root" "rc=$diff_rc"
        # Truncate the artifact so downstream consumers can't be confused by
        # a partial write.
        : > "$output_diff_patch"
        _diff_failure="true"
    fi

    # Lossless readback: `cat file; printf x` round-trips the trailing newline
    # through a bash variable for the downstream stats parsers + scope check.
    local diff_content=""
    if [[ -s "$output_diff_patch" ]]; then
        diff_content="$(cat "$output_diff_patch"; printf x)"
        diff_content="${diff_content%x}"
    fi

    # #530 invariant: if a non-empty diff doesn't end in \n, restore it.
    # This canary catches any future regression of the trailing-newline
    # contract — should never fire after the direct-to-disk write above,
    # but defense in depth.
    if [[ -s "$output_diff_patch" ]]; then
        local _last_byte
        _last_byte="$(tail -c1 "$output_diff_patch" | od -An -tx1 | tr -d ' \n')"
        if [[ "$_last_byte" != "0a" ]]; then
            printf '\n' >> "$output_diff_patch"
            diff_content+=$'\n'
            emit_event "build.diff.trailing_newline_restored" "plugin=build" \
                "last_byte=0x${_last_byte}" >/dev/null 2>&1 || true
        fi
    fi

    # #530 NUL detection: bash variables can't safely carry NUL bytes; binary
    # diffs would otherwise truncate silently in `diff_content`. The on-disk
    # file is fine (we never load it into bash), but the stats parsers below
    # would be misled. Flag explicitly so the gate fails-CLOSED rather than
    # producing misleading numstat output.
    # #549: use `perl -0777 -ne 'exit(!/\x00/)'` instead of `grep -qP`.
    # macOS BSD grep does not support `-P`; `grep -qP '\x00' 2>/dev/null` would
    # exit 2 silently → fail-OPEN on every diff (never flag binary). Perl is
    # always available on macOS + ubuntu CI runners.
    if [[ -s "$output_diff_patch" ]] && \
       LC_ALL=C perl -0777 -ne 'exit(!/\x00/)' "$output_diff_patch" 2>/dev/null; then
        emit_event "build.diff.binary_truncation_observed" "plugin=build" \
            "path=$output_diff_patch" >/dev/null 2>&1 || true
    fi

    # NB: the `git add -N` intent-to-add entries stay in the index through
    # the scope-validation block below (`git diff --name-status -z HEAD`
    # needs them to surface new untracked files). They're cleared at the
    # end of the function via `_build_reset_intent_to_add` so the test
    # stage's `git apply` sees a clean index.

    # ─── Scope post-validation via git diff --name-status -z ─────────────────
    local scope_violation="false"
    local -a scope_violations=()
    # #870: out-of-scope files the build CREATED this iter (git status A). These
    # are candidates for governed auto-grant of build-created collateral (a new
    # golden/fixture/config the change produces that design didn't scope).
    local -a scope_violations_created=()
    if [[ -n "$diff_content" && -n "$plan_files_csv" ]]; then
        local -a allowed_files=()
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        # SC2206: word-split intentional. SC2034: passed to _build_path_in_scope
        # via nameref (local -n _allowed_ref), which shellcheck cannot follow.
        allowed_files=( $plan_files_csv )
        IFS="$IFS_save"

        # name-status -z output: <STATUS>\0<path1>[\0<path2>] for renames.
        # NULs are stripped by command substitution; route through a temp file
        # so the NUL-delimited tokens survive intact.
        local _ns_file="$artifact_dir/.build-name-status.bin"
        git -C "$repo_root" diff --name-status -z HEAD > "$_ns_file" 2>/dev/null || :

        local -a tokens=()
        while IFS= read -r -d '' tok; do
            tokens+=("$tok")
        done < "$_ns_file"
        rm -f "$_ns_file"

        local i n=${#tokens[@]}
        i=0
        while (( i < n )); do
            local status="${tokens[$i]}"
            i=$((i+1))
            local first_path="${tokens[$i]:-}"
            i=$((i+1))
            local -a paths_to_check=("$first_path")
            # Renames/copies (R*/C*) emit two paths: old + new.
            if [[ "$status" =~ ^[RC] ]]; then
                paths_to_check+=("${tokens[$i]:-}")
                i=$((i+1))
            fi
            local p
            for p in "${paths_to_check[@]}"; do
                [[ -z "$p" ]] && continue
                if ! _build_path_in_scope "$p" allowed_files; then
                    scope_violation="true"
                    scope_violations+=("$p")
                    # #870: a NEWLY-created (status A) OOS file is a candidate
                    # for created-collateral auto-grant (classified in the
                    # request helper; only collateral classes are requested).
                    [[ "$status" =~ ^A ]] && scope_violations_created+=("$p")
                    emit_event "build.scope.violation" "plugin=build" \
                        "path=$p" "status=$status"
                fi
            done
        done
    fi

    # #498: capture numstat BEFORE the scope-violation zero-out so the operator
    # banner (emitted after the summary) can surface what the LLM attempted
    # even when diff_content is forcibly emptied below.
    local pre_zero_numstat=""
    if [[ "$scope_violation" == "true" ]]; then
        pre_zero_numstat="$(git -C "$repo_root" diff HEAD --numstat 2>/dev/null || true)"
        # #827: distinguish "LLM deliberately wrote out-of-scope" (clean run
        # rc<2) from "timeout caught LLM mid-edit, partial work happens to
        # touch OOS" (rc>=2 fatal). The clean-run case keeps the existing
        # fail-CLOSED empty-diff behavior — LLM had time to follow the
        # contract and chose not to, so refuse to propagate. The timeout
        # case reverts only the OOS paths and preserves the in-scope diff;
        # otherwise the dogfood build_test_cycle loop reproduces (real
        # in-scope work is lost on every triple-timeout). The pipeline
        # can then commit the in-scope work and the cycle progresses.
        if [[ $router_rc -ge 2 ]]; then
            warn "_build_stage_run_inner: scope violation under router rc=$router_rc — reverting OOS paths, preserving in-scope diff (#827)"
            local _oos_path
            for _oos_path in "${scope_violations[@]}"; do
                [[ -z "$_oos_path" ]] && continue
                # Restore tracked OOS files to HEAD state. For untracked OOS
                # files (no HEAD entry), unlink them — checkout would no-op.
                if git -C "$repo_root" ls-files --error-unmatch -- "$_oos_path" >/dev/null 2>&1; then
                    git -C "$repo_root" checkout HEAD -- "$_oos_path" 2>/dev/null || true
                else
                    rm -f "$repo_root/$_oos_path" 2>/dev/null || true
                fi
            done
            # Re-capture diff after OOS revert. The diff now reflects only
            # in-scope work, which is safe to commit.
            git -C "$repo_root" diff HEAD > "$output_diff_patch" 2>/dev/null || true
            if [[ -s "$output_diff_patch" ]]; then
                diff_content="$(cat "$output_diff_patch"; printf x)"
                diff_content="${diff_content%x}"
            else
                diff_content=""
            fi
            # Important: clear scope_violation flag so downstream (verdict,
            # commit semantics, scope-violation events) treats this iter as
            # a normal timeout-error build with in-scope work to commit.
            # OOS detail is preserved in the new event below for forensics
            # AND in scope_violations[] for the build-summary's audit field.
            scope_violation="false"
            emit_event "build.timeout.partial_work_preserved" "plugin=build" \
                "router_rc=$router_rc" \
                "oos_paths_reverted=${#scope_violations[@]}" \
                "in_scope_diff_bytes=${#diff_content}"
        else
            warn "_build_stage_run_inner: scope violation — writing empty diff.patch"
            # REC-2 (#880): revert EDITED out-of-scope files to HEAD so (a) the
            # working tree is clean for the next iter and (b) the OLD value is
            # restored for the scope_expansion_request evidence check below.
            # `checkout HEAD` no-ops on created (untracked) files — those are
            # left in place for the #870 created-collateral lane.
            local _rev_path
            for _rev_path in "${scope_violations[@]}"; do
                [[ -z "$_rev_path" ]] && continue
                git -C "$repo_root" checkout HEAD -- "$_rev_path" 2>/dev/null || true
            done
            diff_content=""
            # #530: file was already written directly above; zero it now.
            : > "$output_diff_patch"
        fi
    fi

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

    # ─── Write build-summary.json (schema_version=2) ─────────────────────────
    local issue="${ZBUILD_ISSUE:-0}"
    [[ "$issue" =~ ^[0-9]+$ ]] || issue=0

    local violations_json="[]"
    if [[ ${#scope_violations[@]} -gt 0 ]]; then
        violations_json="$(printf '%s\n' "${scope_violations[@]}" \
            | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
    fi

    # #507: .verdict field paired with .scope_violation drives the runner's
    # stage-complete indicator (ADR-020 amendment).
    # #602: schema_version 4 — `apply_check` field removed with the stash dance.
    # Wave 19-D-3 (#733): empty-diff done_sentinel is a structural failure.
    # Dogfood 20260605140602-80831 iter 3 saw the LLM emit done_sentinel
    # WITHOUT producing any code changes — verdict was "pass" so the cycle
    # consumed an iter on no progress. Setting verdict=empty_diff classifies
    # to fail via verdict_classify so the cycle's plateau/divergence detector
    # sees real signal and the outer cycle's predicate sees an honest result.
    local build_verdict="pass"
    [[ "$scope_violation" == "true" ]] && build_verdict="scope_violation"
    if [[ "$terminated_reason" == "done_sentinel" \
          && "${files_changed_count:-0}" -eq 0 \
          && "$scope_violation" != "true" ]]; then
        build_verdict="empty_diff"
    fi

    # #792: post-LLM no-progress diagnostic. When build emitted LOOP_COMPLETE
    # with empty diff AND prior_test_assessment named files outside plan
    # scope, enrich build-summary.json with reason=no_progress_scope_blocked.
    # NOT a short-circuit (build's LLM already ran with the feedback in its
    # prompt — see _feedback_body splice at line ~155). The signal tells the
    # operator "build's LLM tried but couldn't fix this without broader scope."
    local build_reason=""
    local out_of_scope_files_json="[]"
    # #840 (ADR-030): the scope_expansion_request the cycle orchestrator reads.
    local scope_expansion_request_json=""
    if [[ "$build_verdict" == "empty_diff" && -n "${_feedback_body:-}" && -n "$plan_files_csv" ]]; then
        local _oos_paths
        _oos_paths="$(_build_detect_out_of_scope_files "$_feedback_body" "$plan_files_csv")"
        if [[ -n "$_oos_paths" ]]; then
            build_reason="no_progress_scope_blocked"
            out_of_scope_files_json="$(printf '%s\n' "$_oos_paths" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
            # Turn the OOS files into a governed scope_expansion_request. The
            # orchestrator resolves it against the cycle's scope_policy: grant
            # (build retries with the file in scope) / deny (blocked_on_scope,
            # clean abandon). Replaces the old silent dead-end.
            scope_expansion_request_json="$(_build_scope_expansion_request "$_oos_paths" "$_feedback_body" 2>/dev/null || true)"
        fi
    fi

    # #870: a build that CREATED an auto-grant-class collateral file the design
    # didn't scope (a new golden/fixture/config the change produces) must emit a
    # governed request for it (created:true) — not silently fail-close into a
    # scope_violation loop. Fires on the scope_violation verdict path (mutually
    # exclusive with the empty_diff branch above). The orchestrator resolves it:
    # grant (build retries with the file in scope → commits) / deny (one-shot
    # blocked_on_scope abandon).
    if [[ -z "$scope_expansion_request_json" && ${#scope_violations_created[@]} -gt 0 ]]; then
        scope_expansion_request_json="$(_build_created_collateral_request "${scope_violations_created[@]}" 2>/dev/null || true)"
    fi

    # REC-1 (#879): build did valid in-scope work (verdict=pass) but the prior
    # assessment feedback names out-of-scope files the change still requires —
    # the full suite is red because of them. Emit a governed request so the
    # cycle grants collateral and the next iter fixes them; never converge a
    # clean "pass" while OOS files are unrequested, never loop. Mutually
    # exclusive with the branches above via the -z guard.
    if [[ -z "$scope_expansion_request_json" ]]; then
        scope_expansion_request_json="$(_build_pending_collateral_request \
            "$build_verdict" "${_feedback_body:-}" "$plan_files_csv" 2>/dev/null || true)"
        if [[ -n "$scope_expansion_request_json" ]]; then
            build_reason="scope_request_pending"
            out_of_scope_files_json="$(jq -c '[.files[].path]' \
                <<<"$scope_expansion_request_json" 2>/dev/null || echo '[]')"
        fi
    fi

    # REC-2 (#880): build EDITED existing out-of-scope collateral in a clean run
    # (verdict=scope_violation). The clean-run revert above restored those files
    # to HEAD, so the old value is present for the evidence check. Emit a governed
    # request for the edited (non-created) OOS files so the cycle grants
    # collateral and the next iter legitimately edits them — instead of silently
    # discarding the edit. One request class per iter (precedence: empty_diff →
    # created → REC-1 → this): if an iter both creates AND edits OOS collateral,
    # the created request lands first and the edited file (already reverted to
    # HEAD, so the tree stays clean) surfaces on the next iter. Mutually
    # exclusive with the branches above.
    if [[ -z "$scope_expansion_request_json" && ${#scope_violations[@]} -gt 0 ]]; then
        scope_expansion_request_json="$(_build_edited_collateral_request \
            "${_feedback_body:-}" \
            "$(printf '%s\n' "${scope_violations_created[@]:-}")" \
            "$(printf '%s\n' "${scope_violations[@]}")" 2>/dev/null || true)"
        if [[ -n "$scope_expansion_request_json" ]]; then
            build_reason="${build_reason:-scope_request_pending}"
            out_of_scope_files_json="$(jq -c '[.files[].path]' \
                <<<"$scope_expansion_request_json" 2>/dev/null || echo '[]')"
        fi
    fi

    # #602: the post-loop apply-check (introduced in #509, extended bidirectional
    # in #530) ran `git stash push -u` → `git apply --check` → `git stash pop`
    # to validate the patch against a clean tree. `git stash pop` is best-effort
    # and silently failed in the presence of conflicts, leaving the LLM's edits
    # hidden in the stash. The next `git diff HEAD` read 0 lines and the build
    # appeared empty. Removed entirely — captured `git diff HEAD` IS the
    # canonical diff; applicability is established by the LLM editing the
    # files in place via Edit/Write tools, not by post-hoc machinery.

    jq -n \
        --argjson schema_version 4 \
        --argjson issue "$issue" \
        --argjson files_changed "$files_changed_json" \
        --argjson lines_added "$lines_added" \
        --argjson lines_removed "$lines_removed" \
        --arg diff_patch_path "$output_diff_patch" \
        --argjson iterations "$iterations" \
        --arg terminated_reason "$terminated_reason" \
        --arg verdict "$build_verdict" \
        --argjson scope_violation "$([[ "$scope_violation" == "true" ]] && echo true || echo false)" \
        --argjson scope_violations "$violations_json" \
        --argjson loop_input_tokens "$loop_input_tokens" \
        --argjson loop_output_tokens "$loop_output_tokens" \
        --arg reason "$build_reason" \
        --argjson out_of_scope_files "$out_of_scope_files_json" \
        --argjson scope_expansion_request "${scope_expansion_request_json:-null}" \
        --arg notes "Build stage completed. Diff written to artifact; not applied." \
        '{
            schema_version: $schema_version,
            issue: $issue,
            files_changed: $files_changed,
            lines_added: $lines_added,
            lines_removed: $lines_removed,
            diff_patch_path: $diff_patch_path,
            iterations: $iterations,
            terminated_reason: $terminated_reason,
            verdict: $verdict,
            scope_violation: $scope_violation,
            scope_violations: $scope_violations,
            loop_input_tokens: $loop_input_tokens,
            loop_output_tokens: $loop_output_tokens,
            notes: $notes
        }
        + (if $reason != "" then {reason: $reason, out_of_scope_files: $out_of_scope_files} else {} end)
        + (if $scope_expansion_request != null then {scope_expansion_request: $scope_expansion_request} else {} end)
        ' | atomic_write "$output_summary_json"

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
    _build_commit_iteration \
        "$repo_root" \
        "$plan_files_csv" \
        "$scope_violation" \
        "$build_verdict" \
        "${_ROUTE_LOOP_LAST_RESPONSE:-}" \
        "$_plan_title" \
        "$_iter_n" || true

    # ─── #661 / ADR-020 amendment: cumulative baseline→HEAD rewrite ──────────
    # After per-iter commit (#608) lands the work, rewrite diff.patch as the
    # CUMULATIVE branch delta `git diff $intake_baseline..HEAD`, not the
    # per-iter working-tree delta captured above. This makes the artifact
    # represent the branch's full work-so-far across all build iterations and
    # lets the test stage rsync+apply against a baseline snapshot without
    # dup-applying already-committed content.
    #
    # The earlier `git diff HEAD` capture (line ~252) drove scope validation
    # and numstat parsing — those need the pre-commit working-tree view and
    # are now done. The artifact at $output_diff_patch is overwritten here.
    #
    # Scope-violation path skips this rewrite: the artifact was already zeroed
    # at line ~374 and the commit was skipped, so cumulative == zero anyway.
    # Fallback (no baseline ref) preserves pre-#617 behavior by re-emitting
    # `git diff HEAD` — empty after commit but identical to the legacy
    # resumed-run path.
    # Skip the cumulative rewrite when:
    #   - scope_violation: artifact already zeroed; commit was skipped.
    #   - _diff_failure: the original `git diff HEAD` already failed and
    #     fired loop.git_diff_failed; re-running the same primitive in the
    #     non-baseline fallback below would emit a duplicate event and
    #     break golden parity goldens (tests/golden/parity/event-sequence).
    #     When a baseline ref IS present, the rewrite is worth retrying
    #     against the baseline regardless of the working-tree-diff failure.
    if [[ "$scope_violation" != "true" ]]; then
        # state_dir convention: artifact_dir == $state_dir/artifacts (per
        # build_stage_run). The intake-baseline-ref.txt lives at the
        # state_dir root per plugins/agent/intake/plugin.sh:375. Prefer the
        # caller-derived state_dir over $ZBUILD_STATE_DIR so tests that drive
        # build_stage_run with a state_file outside ZBUILD_STATE_DIR (the
        # runner export) still resolve the baseline correctly.
        local _baseline_sha="" _state_dir_for_baseline=""
        _state_dir_for_baseline="$(dirname "$artifact_dir")"
        if [[ -f "$_state_dir_for_baseline/intake-baseline-ref.txt" ]]; then
            _baseline_sha="$(cat "$_state_dir_for_baseline/intake-baseline-ref.txt" \
                2>/dev/null || true)"
        elif [[ -n "${ZBUILD_STATE_DIR:-}" \
              && -f "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" ]]; then
            _baseline_sha="$(cat "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" \
                2>/dev/null || true)"
        fi
        local _do_rewrite="false"
        if [[ -n "$_baseline_sha" ]]; then
            _do_rewrite="true"
        elif [[ "$_diff_failure" != "true" ]]; then
            # Fallback path (no baseline, no prior failure) — retain pre-#617
            # `git diff HEAD` semantics so resumed runs without an intake
            # baseline keep their legacy artifact shape.
            _do_rewrite="true"
        fi
        if [[ "$_do_rewrite" == "true" ]]; then
            local cum_rc=0
            if [[ -n "$_baseline_sha" ]]; then
                git -C "$repo_root" diff "$_baseline_sha..HEAD" \
                    > "$output_diff_patch" 2>/dev/null || cum_rc=$?
            else
                git -C "$repo_root" diff HEAD \
                    > "$output_diff_patch" 2>/dev/null || cum_rc=$?
            fi
            if [[ $cum_rc -ne 0 ]]; then
                warn "_build_stage_run_inner: cumulative diff failed in $repo_root rc=$cum_rc baseline=${_baseline_sha:-<none>}"
                emit_event "loop.git_diff_failed" "plugin=build" \
                    "cwd=$repo_root" "rc=$cum_rc" "phase=cumulative"
                : > "$output_diff_patch"
            fi
        fi
        # #530 trailing-newline invariant — re-enforce on the rewritten file.
        if [[ -s "$output_diff_patch" ]]; then
            local _cum_last_byte
            _cum_last_byte="$(tail -c1 "$output_diff_patch" \
                | od -An -tx1 | tr -d ' \n')"
            if [[ "$_cum_last_byte" != "0a" ]]; then
                printf '\n' >> "$output_diff_patch"
                emit_event "build.diff.trailing_newline_restored" "plugin=build" \
                    "last_byte=0x${_cum_last_byte}" "phase=cumulative" \
                    >/dev/null 2>&1 || true
            fi
        fi
    fi

    emit_event "plugin.run.complete" "stage=build" \
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

# _build_read_acceptance_testfiles <design_md_path> (ADR-031 / #866)
# Returns only the TESTFILES paths from the ```acceptance block in design.md,
# one per line. Empty when design.md is absent, has no acceptance block, or
# the block has no TESTFILES section. Used to inject the acceptance charter
# section into the build prompt so the LLM sees which test files it MUST pass
# and is explicitly prohibited from weakening.
_build_read_acceptance_testfiles() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then
            in_testfiles=1
            continue
        fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"   # tolerate a CRLF design.md
            [[ -z "$line" ]] && continue
            # ADR-031: TESTFILES are repo-relative and grant no write-scope.
            # The list comes from an LLM-produced artifact; mirror design's guard
            # (plugins/agent/design/plugin.sh) and never surface an absolute or
            # ".."-containing path into the build prompt — design would reject it,
            # so the prompt must not advertise it as a target.
            if [[ "$line" == /* || "/$line/" == *"/../"* ]]; then
                continue
            fi
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}

# _build_read_design_decisions <design_md_path>  (ISSUE-E / #916, ADR-020)
# Extract the design.md DECISION PROSE — the narrative/architectural-decision
# summary the design stage writes (plugins/agent/design/plugin.sh) — while
# EXCLUDING every fenced block (```scope / ```acceptance / any ```...). The
# scope + acceptance slices already reach build via _extract_scope_from_design
# and _build_read_acceptance_testfiles; re-injecting them here only burns prompt
# budget. Bounded to _BUILD_DESIGN_DECISIONS_MAX_LINES so a runaway design.md
# can't dominate the build prompt. Empty stdout when design.md is absent or has
# no prose outside fences → caller omits the section entirely (NEVER silent emit).
#
# NB: a naive `sed '/^```/q'` stops at the FIRST fence and drops all prose that
# FOLLOWS the scope/acceptance blocks (design.md routinely has trailing prose).
# We use a fence-TOGGLE so every out-of-fence line survives, in document order.
_BUILD_DESIGN_DECISIONS_MAX_LINES="${_BUILD_DESIGN_DECISIONS_MAX_LINES:-120}"
_build_read_design_decisions() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local body
    body="$(awk -v cap="$_BUILD_DESIGN_DECISIONS_MAX_LINES" '
        /^```/ { infence = !infence; next }
        infence { next }
        { print; emitted++ }
        emitted >= cap { exit }
    ' "$design_md" 2>/dev/null || true)"
    # Trim leading blank lines so the injected block starts tight (sed '/./,$!d'
    # is portable BSD+GNU; trailing blank lines are harmless).
    body="$(printf '%s\n' "$body" | sed '/./,$!d')"
    [[ -z "${body//[[:space:]]/}" ]] && return 0
    printf '%s\n' "$body"
}

# ─── _build_read_prior_assessment (#571, renamed from _build_read_prior_failures)
# Read the prior cycle iter's test_assessment markdown (wired by the cycle
# orchestrator's _cycle_apply_feedback as
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_test_assessment.txt, sourced from the
# test_assessment stage's rendered md output per #567/#568/ADR-022). Returns
# the raw assessment body on stdout OR empty stdout when:
#   - not running in a cycle (ZBUILD_CYCLE_ITER unset)
#   - cycle feedback dir not exported
#   - file missing OR empty (silent-failure guard: `[[ -s file ]]`)
#
# Iter ≥3: the orchestrator overwrites prior_test_assessment.txt each iter
# (cycle-orchestrator.sh:492 `cp "$src" "$dst"`), so reading it naturally
# yields ONLY the most recent prior assessment — no history-trimming needed
# here.
#
# Empty stdout → caller omits the FEEDBACK section entirely (NEVER silent emit).
_build_read_prior_assessment() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_test_assessment.txt"
    # `-s`: present AND non-empty. `-f` alone would let empty-but-present
    # files through and inject a no-op section (silent failure).
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '%s' "$body"
}

# ─── _build_read_prior_review (ADR-026 / Wave 18-B / #707) ────────────────────
# Read the prior outer-cycle iter's review markdown wired by the cycle
# orchestrator's _cycle_apply_feedback as
# $ZBUILD_CYCLE_FEEDBACK_DIR/prior_review_feedback.txt (sourced from the
# review stage's review_md output per ADR-026). Returns the raw review body
# on stdout OR empty stdout when:
#   - not running in a cycle (ZBUILD_CYCLE_ITER unset)
#   - cycle feedback dir not exported
#   - file missing OR empty (silent-failure guard: `[[ -s file ]]`)
#
# Independent of the inner build_test_cycle's prior_test_assessment feedback:
# when build runs as a member of build_test_cycle nested inside review_cycle,
# both feedback files can coexist for the same iter (review feedback came
# from a prior outer iter; test_assessment feedback came from a prior inner
# iter of the current outer iter). Each helper checks its own file.
#
# Empty stdout → caller omits the PRIOR REVIEW FEEDBACK section entirely
# (NEVER silent emit — mirrors _build_read_prior_assessment shape).
_build_read_prior_review() {
    local iter="${ZBUILD_CYCLE_ITER:-}"
    local fb_dir="${ZBUILD_CYCLE_FEEDBACK_DIR:-}"
    [[ -z "$iter" || -z "$fb_dir" ]] && return 0
    local f="$fb_dir/prior_review_feedback.txt"
    [[ ! -s "$f" ]] && return 0
    local body
    body="$(cat "$f" 2>/dev/null)" || return 0
    [[ -z "$body" ]] && return 0
    printf '%s' "$body"
}

# #792: detect when test_assessment's failure_summary_md names file paths
# NOT in plan.files[]. Returns list of out-of-scope paths (one per line),
# empty if none found.
#
# This is a POST-LLM DIAGNOSTIC, not a pre-LLM gate (#784/PR #789 had the
# wrong shape — short-circuited build iter 2 entirely). The helper enriches
# build-summary.json when build emitted LOOP_COMPLETE with empty diff AND
# the prior test_assessment named files outside plan scope. The signal
# tells the operator "build couldn't fix this without broader scope"
# without bypassing the feedback contract.
#
# Heuristic: scan for repo-relative paths (tests/, plugins/, config/, core/,
# scripts/, docs/) followed by NEITHER a colon-digit (line citation) NOR a
# closing-paren-line-citation pattern. Filters citations like "at foo.sh:42"
# (mentioned the file, didn't request a change) while keeping change-requests.
_build_detect_out_of_scope_files() {
    local feedback_body="$1"
    local plan_files_csv="$2"
    [[ -z "$feedback_body" ]] && return 0
    [[ -z "$plan_files_csv" ]] && return 0

    # Strip path:NNN line citations FIRST so they don't survive into the match.
    # e.g. "see foo.sh:42 for context" → "see  for context"
    local cleaned
    cleaned="$(printf '%s' "$feedback_body" \
        | sed -E 's#(tests|plugins|config|core|scripts|docs)/[A-Za-z0-9_./-]+\.(sh|json|yaml|md|golden|txt):[0-9]+##g' \
        2>/dev/null || true)"

    # Match remaining repo-relative paths (change-requests, not citations).
    local matches
    matches="$(printf '%s' "$cleaned" \
        | grep -oE '(tests|plugins|config|core|scripts|docs)/[A-Za-z0-9_./-]+\.(sh|json|yaml|md|golden|txt)' \
        2>/dev/null | sort -u || true)"
    [[ -z "$matches" ]] && return 0

    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        case ",$plan_files_csv," in
            *",$m,"*) ;;
            *) printf '%s\n' "$m" ;;
        esac
    done <<< "$matches"
}

# _build_scope_expansion_request <oos_files_newline> <feedback_body> (#840)
# Builds an ADR-030 scope_expansion_request from the out-of-scope files build is
# blocked on. Per file: classify by path-shape (scope_collateral_class) and
# derive `evidence` — a quoted literal from the test feedback that is ALSO
# present in the file (the OLD value build needs to change; still in the file
# because build hasn't been allowed to change it). Files with no derivable
# evidence are included with empty evidence — the resolver denies those, which
# yields a clean blocked_on_scope abandon, never a loop. Echoes {files:[...]} or
# nothing if there are no files.
_build_scope_expansion_request() {
    local oos="$1" feedback="$2"
    [[ -z "$oos" ]] && return 0
    local _gov; _gov="$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/scope-governance.sh"
    # shellcheck source=/dev/null
    [[ -f "$_gov" ]] && source "$_gov"
    declare -F scope_collateral_class >/dev/null 2>&1 || return 0

    # Candidate evidence tokens: quoted literals (≥2 chars) in the feedback.
    local -a tokens=()
    local _t
    while IFS= read -r _t; do
        [[ -n "$_t" ]] && tokens+=("$_t")
    done < <(printf '%s' "$feedback" \
        | grep -oE "'[^']{2,}'|\"[^\"]{2,}\"" 2>/dev/null \
        | sed -E "s/^['\"]//; s/['\"]\$//" | sort -u)

    local entries="[]" f cls ev
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        cls="$(scope_collateral_class "$f")"
        ev=""
        if [[ -f "$f" ]]; then
            for _t in "${tokens[@]:-}"; do
                [[ -z "$_t" ]] && continue
                if LC_ALL=C grep -qF -- "$_t" "$f" 2>/dev/null; then ev="$_t"; break; fi
            done
        fi
        entries="$(jq -c --arg p "$f" --arg c "$cls" --arg e "$ev" \
            '. + [{path:$p, category:$c, evidence:$e, reason:"build blocked on out-of-scope file named in test feedback"}]' \
            <<<"$entries" 2>/dev/null || printf '%s' "$entries")"
    done <<< "$oos"

    [[ "$entries" == "[]" ]] && return 0
    jq -nc --argjson f "$entries" '{files:$f}' 2>/dev/null || true
}

# _build_pending_collateral_request <verdict> <feedback_body> <plan_files_csv> (REC-1 #879)
# Build did valid IN-SCOPE work (verdict=pass) but the prior-assessment feedback
# names out-of-scope files the change still requires (the suite is red because of
# them). Emit a governed scope_expansion_request so the cycle grants collateral
# and the next iter fixes them — instead of converging "pass" with a red suite
# and looping. Distinct from Path A (empty_diff) and Path B (created): this fires
# when build HAS in-scope edits yet still needs OOS files. Echoes the request
# JSON, or nothing. The resolver (not build) enforces the floor — source files
# are classified structural and denied/escalated, collateral is auto-grantable.
_build_pending_collateral_request() {
    local verdict="$1" feedback="$2" plan_csv="$3"
    [[ "$verdict" == "pass" && -n "$feedback" && -n "$plan_csv" ]] || return 0
    local oos
    oos="$(_build_detect_out_of_scope_files "$feedback" "$plan_csv")"
    [[ -n "$oos" ]] || return 0
    _build_scope_expansion_request "$oos" "$feedback"
}

# _build_edited_collateral_request <feedback> <created_newline> <oos_newline> (REC-2 #880)
# Out-of-scope files build EDITED (not created) in a clean run. The caller reverts
# them to HEAD first so the OLD value is present for the evidence check; this
# reuses the evidence-based request builder (collateral auto-grantable with a
# verified token; source stays structural for the resolver to deny — build only
# constructs). Created files are excluded — they take the #870 created lane.
_build_edited_collateral_request() {
    local feedback="$1" created_nl="$2" oos_nl="$3"
    [[ -z "$oos_nl" ]] && return 0
    local created_csv; created_csv="$(printf '%s' "$created_nl" | tr '\n' ',')"
    local edited="" f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case ",$created_csv," in
            *",$f,"*) ;;          # created → skip (handled by _build_created_collateral_request)
            *) edited+="$f"$'\n' ;;
        esac
    done <<< "$oos_nl"
    edited="${edited%$'\n'}"
    [[ -z "$edited" ]] && return 0
    _build_scope_expansion_request "$edited" "$feedback"
}

# _build_created_collateral_request <created_path> [created_path...]  (#870)
# Build a governed scope_expansion_request for files the build CREATED this iter
# that are out of scope but are auto-grant-class COLLATERAL (new golden/fixture/
# config the change legitimately produces). Each entry carries created:true so
# the resolver grants it on class+floor without a pre-existing evidence token
# (a brand-new file has none). Source-tree/structural created files are dropped
# here (the resolver would deny them anyway) so they don't poison the request
# into an all-or-nothing deny. Echoes {files:[...]} or nothing.
_build_created_collateral_request() {
    (( $# == 0 )) && return 0
    local _gov; _gov="$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/scope-governance.sh"
    # shellcheck source=/dev/null
    [[ -f "$_gov" ]] && source "$_gov"
    declare -F scope_collateral_class >/dev/null 2>&1 || return 0

    local entries="[]" f cls
    for f in "$@"; do
        [[ -z "$f" ]] && continue
        cls="$(scope_collateral_class "$f")"
        # Only request collateral classes; structural/source created files are
        # not auto-grantable and would force an all-deny — leave them to fail.
        [[ "$cls" == collateral_* ]] || continue
        entries="$(jq -c --arg p "$f" --arg c "$cls" \
            '. + [{path:$p, category:$c, created:true, evidence:"", reason:"build created new collateral artifact while implementing the plan"}]' \
            <<<"$entries" 2>/dev/null || printf '%s' "$entries")"
    done

    [[ "$entries" == "[]" ]] && return 0
    jq -nc --argjson f "$entries" '{files:$f}' 2>/dev/null || true
}

# _build_render_task_header <iter> <max_iter>
# Emits the stable banner that prefixes every build prompt. Mirrors the
# legacy `render_task_header` shape (loop-prompt-template.sh) so operators
# eyeballing the [llm] capture see the same framing they had in shipwright.
_build_render_task_header() {
    local iter="${1:-1}"
    local max_iter="${2:-1}"
    printf '============== ZBUILD BUILD — iter %s/%s ==============\n' \
        "$iter" "$max_iter"
}

# _build_compose_instructions <plan_files_csv>
# Emits the INSTRUCTIONS section of the framed prompt — stable scope/loop/
# sentinel/rules text, identical across iterations. Per ADR-018 Pattern 2:
# Read/Edit/Write/Bash tools are available; the loop watches `git diff HEAD`;
# completion is signaled by emitting `LOOP_COMPLETE` on its own line.
_build_compose_instructions() {
    local plan_files_csv="${1:-}"
    local scope_section=""
    if [[ -n "$plan_files_csv" ]]; then
        scope_section="$(printf '%s\n' "$plan_files_csv" | tr ',' '\n' | sed 's/^/  - /')"
    else
        scope_section="  (no plan.files[] declared — refuse to edit if scope is unclear)"
    fi
    cat <<BUILD_PROMPT
You are an autonomous build agent for zBuild. You have Read, Edit, Write, and
Bash tools available. Your job is to edit the working tree to implement the
ORIGINAL TASK above.

### Scope (plan.files[])
You may ONLY touch files listed here. Refuse any out-of-scope edit.
${scope_section}

### How the loop works
- Each iteration you may make code changes via Edit/Write/Bash.
- After each iteration the pipeline captures \`git diff HEAD\` and feeds it
  back to you so you can verify progress.
- Do NOT emit a unified diff in your response — the pipeline derives the
  canonical \`diff.patch\` artifact from \`git diff HEAD\` automatically.

### Completion sentinel
Emit \`LOOP_COMPLETE\` on its own line as the FINAL line of your response
WHEN the implementation is complete — whether you just finished it OR
it was already done before you started. If the branch already contains
the required changes (check \`git log\` for commits + \`git diff\` for any
remaining gap), emit \`LOOP_COMPLETE\` immediately. Do NOT keep iterating
when there is nothing left to do.

### Rules
- Touch only files in the scope list above.
- Do not run \`git commit\` — the pipeline owns commit semantics.
- Keep changes minimal and aligned with the plan.

### Commit message (#608)
Before the final \`LOOP_COMPLETE\` line, emit a single line of the form:

    COMMIT_SUMMARY: <one-line description of this iteration's change>

Keep it under 72 characters, present tense, imperative mood (e.g.
"add foo parser" not "added"). The pipeline uses this as the git commit
message for the per-iteration commit it creates on your behalf. If you
omit this line the pipeline falls back to the plan title.
BUILD_PROMPT
}

# ─── _build_parse_commit_summary <response_text> <plan_title> ────────────────
# Scan response_text (last 50 lines) for `^COMMIT_SUMMARY:[[:space:]]*(.+)$`.
# Takes the LAST match (LLM may correct itself across the response), trims
# whitespace, truncates to 72 chars. Falls back to plan_title (also truncated)
# when no marker is found. If plan_title is also empty, synthesizes a default
# from ZBUILD_CYCLE_ITER. Echoes the message on stdout.
_build_parse_commit_summary() {
    local response="${1:-}"
    local plan_title="${2:-}"
    local msg=""

    if [[ -n "$response" ]]; then
        # Bounded scan: last 50 lines. Captures the LAST COMMIT_SUMMARY line.
        msg="$(printf '%s\n' "$response" \
            | tail -n 50 \
            | grep -E '^COMMIT_SUMMARY:[[:space:]]*(.+)$' \
            | tail -n 1 \
            | sed -E 's/^COMMIT_SUMMARY:[[:space:]]*//' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            || true)"
    fi

    if [[ -z "$msg" ]]; then
        msg="$(printf '%s' "$plan_title" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi

    if [[ -z "$msg" ]]; then
        msg="zbuild: build iter ${ZBUILD_CYCLE_ITER:-1}"
    fi

    # Truncate to 72 chars (git short-message convention).
    printf '%s' "$msg" | cut -c1-72
}

# ─── _build_commit_iteration ────────────────────────────────────────────────
# Post-loop commit logic (#608). Honors the build prompt contract: "the
# pipeline owns commit semantics" — invoked OUTSIDE the LLM, AFTER the loop.
#
# Args:
#   $1 = repo_root
#   $2 = plan_files_csv (scope allowlist; what we `git add`)
#   $3 = scope_violation ("true"/"false")
#   $4 = build_verdict (currently "pass" or "scope_violation")
#   $5 = response_text  (last LLM iteration's text, for COMMIT_SUMMARY)
#   $6 = plan_title     (fallback commit message)
#   $7 = iter           (the cycle iter, for event metadata; 1 outside cycle)
#
# Side effects:
#   - On scope_violation: emit build.commit.skipped reason=scope_violation
#   - On empty staged diff: emit build.commit.skipped reason=empty_diff
#   - On success: git commit + emit build.commit.created sha=<sha> msg=<msg>
_build_commit_iteration() {
    local repo_root="$1"
    local plan_files_csv="$2"
    local scope_violation="$3"
    local build_verdict="$4"
    local response_text="$5"
    local plan_title="$6"
    local iter="${7:-1}"

    if [[ "$scope_violation" == "true" || "$build_verdict" == "scope_violation" ]]; then
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=scope_violation" "iter=$iter"
        return 0
    fi

    # Clear `git add -N` intent-to-add entries left by the loop so the
    # subsequent `git add -- <paths>` stages real content (not just an
    # empty intent marker that produces an empty staged diff).
    git -C "$repo_root" reset -q 2>/dev/null || true

    # Stage only in-scope files that actually exist (or are tracked).
    local -a files_arr=()
    if [[ -n "$plan_files_csv" ]]; then
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206
        files_arr=( $plan_files_csv )
        IFS="$IFS_save"
    fi

    local -a add_args=()
    local f
    for f in "${files_arr[@]}"; do
        [[ -z "$f" ]] && continue
        if [[ -e "$repo_root/$f" ]] || \
           git -C "$repo_root" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
            add_args+=("$f")
        fi
    done

    if [[ ${#add_args[@]} -eq 0 ]]; then
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    fi

    git -C "$repo_root" add -- "${add_args[@]}" 2>/dev/null || {
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    }

    # If nothing actually got staged (all files identical), skip.
    if git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=empty_diff" "iter=$iter"
        return 0
    fi

    local commit_msg
    commit_msg="$(_build_parse_commit_summary "$response_text" "$plan_title")"

    if ! git -C "$repo_root" commit \
        --author "zbuild-pipeline <pipeline@local>" \
        --no-verify --quiet \
        -m "$commit_msg" 2>/dev/null; then
        warn "_build_commit_iteration: git commit failed in $repo_root"
        emit_event "build.commit.skipped" "plugin=build" \
            "reason=commit_failed" "iter=$iter"
        return 0
    fi

    local sha
    sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '')"
    emit_event "build.commit.created" "plugin=build" \
        "sha=$sha" "msg=$commit_msg" "iter=$iter"
    return 0
}

# _build_path_in_scope <path> <allowed_files_array_name>
# Thin wrapper around the shared _numstat_path_in_scope helper (#506).
_build_path_in_scope() {
    _numstat_path_in_scope "$@"
}

# ─── _build_format_numstat ──────────────────────────────────────────────────
# Thin wrapper around the shared format_numstat (#506). Delegates to the
# extracted helper with build's defaults (event prefix=build, full-at
# pointer=build-summary.json) and mirrors _NUMSTAT_FILES_COUNT into the
# legacy _BUILD_NUMSTAT_FILES_COUNT name the caller still reads.
_BUILD_NUMSTAT_MAX_LINES=50
_BUILD_NUMSTAT_FILES_COUNT=0
_build_format_numstat() {
    local raw="$1"
    local allowed_name="$2"
    # event-prefix=build → emits "build.numstat.truncated" (stable name).
    format_numstat "$raw" "$allowed_name" \
        --event-prefix "build" \
        --full-at "build-summary.json"
    _BUILD_NUMSTAT_FILES_COUNT="$_NUMSTAT_FILES_COUNT"
    return 0
}

# ─── _build_emit_changed_files_summary ──────────────────────────────────────
# Emit the post-loop kind=computed stage_io banner showing `git diff HEAD
# --numstat` so the operator sees what the build loop actually changed on
# disk (independent of the LLM's per-iteration prose).
#
# Args:
#   $1 = repo_root
#   $2 = terminated_reason (from _ROUTE_LOOP_TERMINATED_REASON)
#   $3 = scope_violation ("true"/"false")
#   $4 = pre_zero_numstat (captured BEFORE diff zero-out on scope violation)
#
# Side effects (#587: no stage_io banner pair — event-only signal):
#   - emits build.numstat.precondition_failed when git rev-parse HEAD fails
#   - emits build.discrepancy.detected when LOOP_COMPLETE + 0 files (legacy name)
#   - emits build.diff.empty_after_done_sentinel for the same condition (#587)
#   - emits build.numstat.truncated via _build_format_numstat when capped
#   - writes one-line stderr `warn` for operator-visible signal in both
#     the precondition-fail and discrepancy paths (no FD-3 banner)
_build_emit_changed_files_summary() {
    local repo_root="$1"
    local terminated_reason="$2"
    local scope_violation="$3"
    local pre_zero_numstat="$4"

    # #587: stage_id retained for any future event metadata; no banner pair.
    local _stage_id_unused="${ZBUILD_CURRENT_STAGE:-build}"
    : "$_stage_id_unused"

    # ── Pre-check git state (detached HEAD, mid-rebase, unborn branch) ──────
    if ! git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
        local reason="unknown"
        if [[ -d "$repo_root/.git/rebase-merge" || -d "$repo_root/.git/rebase-apply" ]]; then
            reason="rebase"
        elif [[ -f "$repo_root/.git/BISECT_LOG" ]]; then
            reason="bisect"
        elif [[ -f "$repo_root/.git/MERGE_HEAD" ]]; then
            reason="merge"
        elif ! git -C "$repo_root" symbolic-ref -q HEAD >/dev/null 2>&1; then
            reason="detached"
        else
            reason="unborn"
        fi
        emit_event "build.numstat.precondition_failed" "plugin=build" \
            "reason=$reason" "repo_root=$repo_root" >/dev/null 2>&1 || true
        # #587: replace [computed] banner pair with single-line stderr warn.
        warn "build: numstat skipped (git state $reason)" >&2 || true
        return 0
    fi

    # ── Run numstat (use pre-zeroed snapshot on scope_violation) ───────────
    local numstat_out=""
    local scope_violation_mode="false"
    if [[ "$scope_violation" == "true" ]]; then
        numstat_out="$pre_zero_numstat"
        scope_violation_mode="true"
    else
        numstat_out="$(git -C "$repo_root" diff HEAD --numstat 2>/dev/null || true)"
    fi

    # ── Build allow-list from plan_files_csv (caller-scoped via env) ───────
    # We don't have direct access to plan_files_csv here; reconstruct from
    # ZBUILD_SCOPE_MANIFEST or fall back to empty (which disables redaction).
    # The simpler approach: caller passes via env var BUILD_PLAN_FILES_CSV.
    local -a allowed_files=()
    local _csv="${_BUILD_PLAN_FILES_CSV:-}"
    if [[ -n "$_csv" ]]; then
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        # SC2206: word-split intentional. SC2034: passed to _build_format_numstat
        # via nameref (local -n _fmt_allowed_ref), which shellcheck cannot follow.
        allowed_files=( $_csv )
        IFS="$IFS_save"
    fi

    # ── Format with redaction + truncation ─────────────────────────────────
    # NB: capture via tmp file (not $()) so _BUILD_NUMSTAT_FILES_COUNT,
    # which _build_format_numstat sets on the caller, isn't lost across a
    # subshell boundary. The $(_build_format_numstat …) path would forfeit
    # the count and force a discrepancy false-positive (caught by #498's
    # integration test).
    local _fmt_tmp; _fmt_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-numstat.XXXXXX")"
    _build_format_numstat "$numstat_out" allowed_files > "$_fmt_tmp"
    local formatted; formatted="$(cat "$_fmt_tmp")"
    rm -f "$_fmt_tmp"
    local files_count="$_BUILD_NUMSTAT_FILES_COUNT"

    # ── Discrepancy: LOOP_COMPLETE + 0 files changed ──────────────────────
    # #587: removed [computed] stage_io banner pair entirely. Signal lives in
    # two events (legacy `build.discrepancy.detected` for backward-compat +
    # new `build.diff.empty_after_done_sentinel`) plus a single-line stderr
    # `warn` for operator visibility. The duration/start_ms accounting is
    # likewise gone since there's no banner to attach it to; events carry
    # their own timestamps via the bus.
    if [[ "$terminated_reason" == "done_sentinel" && "$files_count" -eq 0 \
          && "$scope_violation_mode" != "true" ]]; then
        emit_event "build.discrepancy.detected" "plugin=build" \
            "reason=loop_complete_no_changes" \
            "terminated_reason=$terminated_reason" \
            "files_changed=0" >/dev/null 2>&1 || true
        emit_event "build.diff.empty_after_done_sentinel" "plugin=build" \
            "terminated_reason=$terminated_reason" \
            "files_changed=0" >/dev/null 2>&1 || true
        warn "build: LLM signaled success but numstat shows 0 files changed" >&2 || true
    fi

    # #587: `formatted` is computed only as a side-effect of populating
    # `_BUILD_NUMSTAT_FILES_COUNT` (consumed by the discrepancy check above).
    # No banner reads it anymore; touch to silence shellcheck.
    : "${formatted:-}"
    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
build_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=build"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
build_stage_cleanup() {
    emit_event "plugin.cleanup.complete" "plugin=build"
    return 0
}

# #754: parse a ```scope fenced block in design.md and return a CSV of files.
# Empty when no fenced block found.
# legacy-citation: legacy/scripts/lib/pipeline-stages.sh:38-71
_extract_scope_from_design() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0

    local in_block=0
    local -a files=()
    while IFS= read -r line; do
        if [[ "$line" == '```scope' ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            break
        fi
        if [[ $in_block -eq 1 && -n "$line" ]]; then
            files+=("$line")
        fi
    done < "$design_md"

    if [[ ${#files[@]} -gt 0 ]]; then
        local IFS=','
        printf '%s' "${files[*]}"
    fi
}
