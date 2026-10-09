#!/usr/bin/env bash
# Sourced modules inherit caller's strict mode; set here for self-contained
# consistency with other lib modules (e.g., error-actionability.sh).
set -euo pipefail
# Module guard — prevent double-sourcing
[[ -n "${_LOOP_CONTEXT_MONITOR_LOADED:-}" ]] && return 0
_LOOP_CONTEXT_MONITOR_LOADED=1

# ─── Context Exhaustion Prevention ────────────────────────────────────────────
# Tracks cumulative token usage across iterations and triggers proactive
# summarization + session restart before Claude's context window is exhausted.

# Defaults — override via env vars
CONTEXT_WINDOW_TOKENS="${CONTEXT_WINDOW_TOKENS:-200000}"    # claude-opus-4-6/sonnet-4-6
CONTEXT_EXHAUSTION_THRESHOLD="${CONTEXT_EXHAUSTION_THRESHOLD:-70}"  # % trigger point

# get_context_usage_pct()
# Returns current cumulative token usage as integer percentage of context window.
# Outputs 0 if token data is unavailable or window size is 0.
get_context_usage_pct() {
    local window="${CONTEXT_WINDOW_TOKENS:-200000}"
    local input="${LOOP_INPUT_TOKENS:-0}"
    local output="${LOOP_OUTPUT_TOKENS:-0}"

    # Guard: division by zero
    if [[ "$window" -le 0 ]]; then
        echo "0"
        return 0
    fi

    local cumulative=$(( input + output ))
    # Integer math: (cumulative * 100) / window
    echo $(( cumulative * 100 / window ))
}

# check_context_exhaustion()
# Returns 0 (true) if cumulative token usage has crossed the exhaustion threshold.
# Returns 1 (false) if still safe.
# Emits loop.context_exhaustion_warning event when threshold is crossed.
check_context_exhaustion() {
    local threshold="${CONTEXT_EXHAUSTION_THRESHOLD:-70}"
    local window="${CONTEXT_WINDOW_TOKENS:-200000}"
    local input="${LOOP_INPUT_TOKENS:-0}"
    local output="${LOOP_OUTPUT_TOKENS:-0}"

    # Guard: no tokens accumulated yet (first iteration or jq unavailable)
    if [[ "$input" -eq 0 && "$output" -eq 0 ]]; then
        return 1
    fi

    local usage_pct
    usage_pct="$(get_context_usage_pct)"

    if [[ "$usage_pct" -ge "$threshold" ]]; then
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.context_exhaustion_warning" \
                "iteration=${ITERATION:-0}" \
                "usage_pct=$usage_pct" \
                "threshold=$threshold" \
                "input_tokens=$input" \
                "output_tokens=$output" \
                "window=$window" || \
                echo "WARNING: Could not emit loop.context_exhaustion_warning event" >&2
        fi
        return 0  # exhaustion threshold crossed
    fi
    return 1  # still safe
}

# summarize_loop_state()
# Writes a compressed state summary to $LOG_DIR/context-summary.md.
# Includes: goal, iteration count, test status, modified files, recent errors.
# Prints the path to the summary file on stdout.
summarize_loop_state() {
    local log_dir="${LOG_DIR:-/tmp}"
    local summary_file="$log_dir/context-summary.md"
    local tmp_file="${summary_file}.tmp.$$"

    local usage_pct
    usage_pct="$(get_context_usage_pct)"

    {
        printf '# Context Summary (Auto-generated at iteration %s)\n\n' "${ITERATION:-0}"
        printf '## Goal\n%s\n\n' "${ORIGINAL_GOAL:-${GOAL:-unknown}}"

        printf '## Session Status\n'
        printf '- Iteration: %s/%s\n' "${ITERATION:-0}" "${MAX_ITERATIONS:-20}"
        printf '- Context usage: %s%% of %s tokens\n' "$usage_pct" "${CONTEXT_WINDOW_TOKENS:-200000}"
        printf '- Test status: %s\n' "${TEST_PASSED:-unknown}"
        printf '- Consecutive failures: %s\n\n' "${CONSECUTIVE_FAILURES:-0}"

        # Files modified since loop start
        printf '## Modified Files\n'
        local modified_files=""
        if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
            modified_files="$(cd "${PROJECT_ROOT:-.}" && git diff --name-only "${LOOP_START_COMMIT}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths | head -20 || true)"
        fi
        if [[ -z "$modified_files" ]]; then
            modified_files="$(cd "${PROJECT_ROOT:-.}" && git diff --name-only HEAD -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths | head -20 || true)"
        fi
        if [[ -n "$modified_files" ]]; then
            while IFS= read -r f; do
                printf '- %s\n' "$f"
            done <<< "$modified_files"
        else
            printf '- (no changes detected)\n'
        fi
        printf '\n'

        # Last error summary
        printf '## Recent Errors\n'
        local error_summary_file="$log_dir/error-summary.json"
        if [[ -f "$error_summary_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                local err_type err_msg
                err_type="$(jq -r '.error_type // "unknown"' "$error_summary_file" 2>/dev/null || true)"
                err_msg="$(jq -r '.error_message // ""' "$error_summary_file" 2>/dev/null | head -3 || true)"
                [[ -n "$err_type" && "$err_type" != "null" && "$err_type" != "unknown" ]] && printf '- Type: %s\n' "$err_type"
                [[ -n "$err_msg" && "$err_msg" != "null" ]] && printf '- Message: %s\n' "$(echo "$err_msg" | head -1)"
            else
                head -5 "$error_summary_file" 2>/dev/null | sed 's/^/  /' || true
            fi
        else
            printf '- (no errors recorded)\n'
        fi
        printf '\n'

        # Last log entries from this session (capped for summary brevity)
        printf '## Recent Progress\n'
        if [[ -n "${LOG_ENTRIES:-}" ]]; then
            echo "$LOG_ENTRIES" | tail -30 | head -20
        else
            printf '- (no log entries)\n'
        fi
        printf '\n'
    } > "$tmp_file"

    if mv "$tmp_file" "$summary_file" 2>/dev/null; then
        echo "$summary_file"
    else
        warn "Failed to write context summary to $summary_file" 2>/dev/null || true
        echo ""
    fi
}
