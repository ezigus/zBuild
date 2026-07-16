#!/usr/bin/env bash
# plugins/agent/build/lib/summary.sh — diff stats, numstat, and build-summary.json helpers.
# Sourced by plugin.sh after shared libs (numstat-format.sh, etc.) are loaded.

[[ -n "${_ZBUILD_BUILD_SUMMARY_LOADED:-}" ]] && return 0
_ZBUILD_BUILD_SUMMARY_LOADED=1

# _build_format_numstat — thin wrapper around format_numstat (#506).
_BUILD_NUMSTAT_MAX_LINES=50
_BUILD_NUMSTAT_FILES_COUNT=0
_build_format_numstat() {
    local raw="$1"
    local allowed_name="$2"
    format_numstat "$raw" "$allowed_name" \
        --event-prefix "build" \
        --full-at "build-summary.json"
    _BUILD_NUMSTAT_FILES_COUNT="$_NUMSTAT_FILES_COUNT"
    return 0
}

# _build_emit_changed_files_summary — post-loop numstat/discrepancy signal (#587).
# Args: $1=repo_root $2=terminated_reason $3=scope_violation $4=pre_zero_numstat
_build_emit_changed_files_summary() {
    local repo_root="$1"
    local terminated_reason="$2"
    local scope_violation="$3"
    local pre_zero_numstat="$4"

    local _stage_id_unused="${ZBUILD_CURRENT_STAGE:-build}"
    : "$_stage_id_unused"

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
        warn "build: numstat skipped (git state $reason)" >&2 || true
        return 0
    fi

    local numstat_out=""
    local scope_violation_mode="false"
    if [[ "$scope_violation" == "true" ]]; then
        numstat_out="$pre_zero_numstat"
        scope_violation_mode="true"
    else
        numstat_out="$(git -C "$repo_root" diff HEAD --numstat 2>/dev/null || true)"
    fi

    local -a allowed_files=()
    local _csv="${_BUILD_PLAN_FILES_CSV:-}"
    if [[ -n "$_csv" ]]; then
        local IFS_save="$IFS"
        IFS=','
        # shellcheck disable=SC2206,SC2034
        allowed_files=( $_csv )
        IFS="$IFS_save"
    fi

    local _fmt_tmp; _fmt_tmp="$(mktemp "${TMPDIR:-/tmp}/zb-numstat.XXXXXX")"
    _build_format_numstat "$numstat_out" allowed_files > "$_fmt_tmp"
    local formatted; formatted="$(cat "$_fmt_tmp")"
    rm -f "$_fmt_tmp"
    local files_count="$_BUILD_NUMSTAT_FILES_COUNT"

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

    : "${formatted:-}"
    return 0
}

# _build_write_build_summary — extracted summary-assembly block from _build_stage_run_inner.
# Uses dynamic scoping: reads issue, scope_violation, scope_violations[],
# scope_violations_created[], files_changed_json, lines_added, lines_removed,
# files_changed_count, output_diff_patch, output_summary_json, iterations,
# terminated_reason, loop_input_tokens, loop_output_tokens, _feedback_body,
# plan_files_csv, router_rc from caller's locals.
# Writes build_verdict back to caller's scope (no `local` on it here).
_build_write_build_summary() {
    local _sum_violations_json="[]"
    local _sum_build_reason=""
    local _sum_out_of_scope_files_json="[]"
    local _sum_scope_expansion_request_json=""
    local _sum_oos_paths

    # Compute verdict.
    build_verdict="pass"
    if [[ "${scope_violation:-false}" == "true" ]]; then
        build_verdict="scope_violation"
    elif [[ "${terminated_reason:-error}" == "router_timeout" || "${terminated_reason:-error}" == "error" ]]; then
        build_verdict="did_not_finish"
    elif [[ "${terminated_reason:-}" == "done_sentinel" \
          && "${files_changed_count:-0}" -eq 0 ]]; then
        build_verdict="empty_diff"
    fi

    if [[ ${#scope_violations[@]} -gt 0 ]]; then
        _sum_violations_json="$(printf '%s\n' "${scope_violations[@]}" \
            | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
    fi

    # #792: post-LLM no-progress diagnostic.
    if [[ "$build_verdict" == "empty_diff" && -n "${_feedback_body:-}" && -n "${plan_files_csv:-}" ]]; then
        _sum_oos_paths="$(_build_detect_out_of_scope_files "$_feedback_body" "$plan_files_csv")"
        if [[ -n "$_sum_oos_paths" ]]; then
            _sum_build_reason="no_progress_scope_blocked"
            _sum_out_of_scope_files_json="$(printf '%s\n' "$_sum_oos_paths" \
                | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
            _sum_scope_expansion_request_json="$(_build_scope_expansion_request "$_sum_oos_paths" "${_feedback_body:-}" 2>/dev/null || true)"
        fi
    fi

    # #870: created OOS collateral request.
    if [[ -z "$_sum_scope_expansion_request_json" && ${#scope_violations_created[@]} -gt 0 ]]; then
        _sum_scope_expansion_request_json="$(_build_created_collateral_request "${scope_violations_created[@]}" 2>/dev/null || true)"
    fi

    # REC-1 (#879): valid in-scope work but feedback names OOS files.
    if [[ -z "$_sum_scope_expansion_request_json" ]]; then
        _sum_scope_expansion_request_json="$(_build_pending_collateral_request \
            "$build_verdict" "${_feedback_body:-}" "${plan_files_csv:-}" 2>/dev/null || true)"
        if [[ -n "$_sum_scope_expansion_request_json" ]]; then
            _sum_build_reason="scope_request_pending"
            _sum_out_of_scope_files_json="$(jq -c '[.files[].path]' \
                <<<"$_sum_scope_expansion_request_json" 2>/dev/null || echo '[]')"
        fi
    fi

    # REC-2 (#880): edited OOS collateral.
    if [[ -z "$_sum_scope_expansion_request_json" && ${#scope_violations[@]} -gt 0 ]]; then
        _sum_scope_expansion_request_json="$(_build_edited_collateral_request \
            "${_feedback_body:-}" \
            "$(printf '%s\n' "${scope_violations_created[@]:-}")" \
            "$(printf '%s\n' "${scope_violations[@]}")" 2>/dev/null || true)"
        if [[ -n "$_sum_scope_expansion_request_json" ]]; then
            _sum_build_reason="${_sum_build_reason:-scope_request_pending}"
            _sum_out_of_scope_files_json="$(jq -c '[.files[].path]' \
                <<<"$_sum_scope_expansion_request_json" 2>/dev/null || echo '[]')"
        fi
    fi

    local _sum_issue="${issue:-0}"
    [[ "$_sum_issue" =~ ^[0-9]+$ ]] || _sum_issue=0

    jq -n \
        --argjson schema_version 4 \
        --argjson issue "$_sum_issue" \
        --argjson files_changed "${files_changed_json:-[]}" \
        --argjson lines_added "${lines_added:-0}" \
        --argjson lines_removed "${lines_removed:-0}" \
        --arg diff_patch_path "${output_diff_patch:-}" \
        --argjson iterations "${iterations:-0}" \
        --arg terminated_reason "${terminated_reason:-error}" \
        --arg verdict "$build_verdict" \
        --argjson scope_violation "$([[ "${scope_violation:-false}" == "true" ]] && echo true || echo false)" \
        --argjson scope_violations "$_sum_violations_json" \
        --argjson loop_input_tokens "${loop_input_tokens:-0}" \
        --argjson loop_output_tokens "${loop_output_tokens:-0}" \
        --arg reason "$_sum_build_reason" \
        --argjson out_of_scope_files "$_sum_out_of_scope_files_json" \
        --argjson scope_expansion_request "${_sum_scope_expansion_request_json:-null}" \
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
}
