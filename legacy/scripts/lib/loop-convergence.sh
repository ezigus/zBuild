#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_CONVERGENCE_LOADED:-}" ]] && return 0
_LOOP_CONVERGENCE_LOADED=1

# Module-scope cache for stuckness detector ruflo throttling (issue #447).
# Survives within a single shell process; the on-disk fingerprint file in
# $LOG_DIR survives session restarts within the same loop run.
: "${_STUCKNESS_RECALL_CACHE:=}"
: "${_STUCKNESS_RECALL_CACHE_FP:=}"
: "${_STUCKNESS_RECALL_CACHE_VALID:=false}"

# Compute a stable fingerprint of (signals, reasons) so identical detection
# patterns can be deduplicated. Falls back to cksum (POSIX-mandatory) when
# md5/md5sum are unavailable, ensuring the output is always a valid 12-char
# lowercase hex string and never empty.
_stuckness_fingerprint() {
    local signals="${1:-0}"
    local reasons="${2:-}"
    local _raw _hash
    _raw=$(printf '%s\n%s\n' "$signals" "$reasons")
    _hash=$(printf '%s' "$_raw" \
        | (md5 -q 2>/dev/null || md5sum 2>/dev/null | awk '{print $1}') \
        | cut -c1-12)
    # Validate: must be exactly 12 lowercase hex chars; cksum fallback if not.
    if [[ "${#_hash}" -ne 12 ]] || ! [[ "$_hash" =~ ^[0-9a-f]+$ ]]; then
        local _crc
        _crc=$(printf '%s' "$_raw" | cksum | awk '{print $1}')
        _hash=$(printf '%012x' "${_crc:-0}")
    fi
    printf '%s' "$_hash"
}

# ─── Convergence Detection ────────────────────────────────────────────────────

track_iteration_velocity() {
    local changes
    changes="$(_git_diff_stat_excluded "$PROJECT_ROOT")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    ITERATION_LINES_CHANGED="${insertions:-0}"
    if [[ -n "$VELOCITY_HISTORY" ]]; then
        VELOCITY_HISTORY="${VELOCITY_HISTORY},${ITERATION_LINES_CHANGED}"
    else
        VELOCITY_HISTORY="${ITERATION_LINES_CHANGED}"
    fi
}

# Compute average lines/iteration from recent history
compute_velocity_avg() {
    if [[ -z "$VELOCITY_HISTORY" ]]; then
        echo "0"
        return 0
    fi
    local total=0 count=0
    local IFS=','
    local val
    for val in $VELOCITY_HISTORY; do
        total=$((total + val))
        count=$((count + 1))
    done
    if [[ "$count" -gt 0 ]]; then
        echo $((total / count))
    else
        echo "0"
    fi
}

check_progress() {
    local new_commits="${1:-}"

    # Iteration-level check: did HEAD advance this iteration?
    # This avoids being fooled by HEAD~1 diffs from prior commits when
    # the current iteration produces no changes (issue #221).
    if [[ -n "$new_commits" ]]; then
        if [[ "${new_commits:-0}" -gt 0 ]]; then
            return 0
        fi
        return 1
    fi

    # Fallback: cumulative diff for non-loop callers (backward compat)
    local changes
    # Exclude bookkeeping and runtime files — only count real code changes as progress
    changes="$(_git_diff_stat_excluded "$PROJECT_ROOT")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${insertions:-0}" -lt "$MIN_PROGRESS_LINES" ]]; then
        return 1  # No meaningful progress
    fi
    return 0
}

check_completion() {
    local log_file="$1"
    detect_gate_signal "$log_file" "LOOP" \
        'LOOP_COMPLETE' \
        '<<<LOOP:FAIL>>>'
}

check_circuit_breaker() {
    # Vitals-driven circuit breaker (preferred over static threshold)
    if type pipeline_compute_vitals >/dev/null 2>&1 && type pipeline_health_verdict >/dev/null 2>&1; then
        local _vitals_json _verdict
        local _loop_state="${STATE_FILE:-}"
        local _loop_artifacts="${ARTIFACTS_DIR:-}"
        local _loop_issue="${ISSUE_NUMBER:-}"
        _vitals_json=$(pipeline_compute_vitals "$_loop_state" "$_loop_artifacts" "$_loop_issue" 2>/dev/null) || true
        if [[ -n "$_vitals_json" && "$_vitals_json" != "{}" ]]; then
            _verdict=$(echo "$_vitals_json" | jq -r '.verdict // "continue"' 2>/dev/null || echo "continue")
            if [[ "$_verdict" == "abort" ]]; then
                local _health_score
                _health_score=$(echo "$_vitals_json" | jq -r '.health_score // 0' 2>/dev/null || echo "0")
                error "Vitals circuit breaker: health score ${_health_score}/100 — aborting (${CONSECUTIVE_FAILURES} stagnant iterations)"
                STATUS="circuit_breaker"
                return 1
            fi
            # Vitals say continue/warn/intervene — don't trip circuit breaker yet
            if [[ "$_verdict" == "continue" || "$_verdict" == "warn" ]]; then
                return 0
            fi
        fi
    fi

    # Fallback: static threshold circuit breaker
    if [[ "$CONSECUTIVE_FAILURES" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
        error "Circuit breaker tripped: ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with no meaningful progress."
        STATUS="circuit_breaker"
        return 1
    fi
    return 0
}

check_time_budget() {
    # Guard: stop starting a new iteration if <20 min remains in the GHA job.
    # Anchors on CI_JOB_START_EPOCH (set once per GHA job by the pipeline workflow,
    # never persisted to disk). Falls back to LOOP_START_EPOCH for standalone
    # `sw loop` invocations with no CI wrapper.
    # PIPELINE_RUN_EPOCH is intentionally NOT read here: it survives across CI jobs
    # via the WIP branch, making it an unsafe budget anchor. It remains the
    # historical "pipeline first start" marker for display purposes only.
    local _job_timeout_min="${SHIPWRIGHT_JOB_TIMEOUT_MINUTES:-0}"
    # Require a valid positive integer — non-numeric values would cause arithmetic
    # errors under set -e; treat them as "no limit" (return 0 = continue loop).
    local _ref_epoch="${CI_JOB_START_EPOCH:-${LOOP_START_EPOCH:-}}"
    [[ -z "$_ref_epoch" || "$_ref_epoch" == "0" ]] && return 0
    [[ ! "$_ref_epoch" =~ ^[0-9]+$ ]] && return 0
    [[ ! "$_job_timeout_min" =~ ^[0-9]+$ || "$_job_timeout_min" -le 0 ]] && return 0
    local _now _elapsed_min _remaining_min
    _now=$(now_epoch 2>/dev/null) || return 0
    _elapsed_min=$(( (_now - _ref_epoch) / 60 ))
    # Stale-epoch defense: GHA hard-kills the job at SHIPWRIGHT_JOB_TIMEOUT_MINUTES,
    # so _elapsed_min > _job_timeout_min is physically impossible during a healthy run.
    # If we see it, the anchor is from a prior CI job — some entry point bypassed
    # the workflow step that sets CI_JOB_START_EPOCH. Continue rather than insta-exit;
    # emit telemetry to surface the regression.
    if (( _elapsed_min > _job_timeout_min )); then
        emit_event "loop.time_budget_stale_ref" \
            "elapsed_min=${_elapsed_min}" \
            "ref_epoch=${_ref_epoch}" \
            "job_timeout_min=${_job_timeout_min}" 2>/dev/null || true
        return 0
    fi
    _remaining_min=$(( _job_timeout_min - _elapsed_min ))
    if (( _remaining_min < 20 )); then
        warn "Less than 20 min remaining in GHA job (${_remaining_min}m) — stopping build loop to allow cleanup"
        STATUS="time_budget_exhausted"
        emit_event "loop.time_budget_exhausted" \
            "elapsed_min=${_elapsed_min}" \
            "remaining_min=${_remaining_min}" \
            "iteration=${ITERATION:-0}" 2>/dev/null || true
        return 1
    fi
    return 0
}

check_max_iterations() {
    if [[ "$ITERATION" -le "$MAX_ITERATIONS" ]]; then
        return 0
    fi

    # Hit the cap — check if we should auto-extend
    if ! $AUTO_EXTEND || [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
        if [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
            warn "Hard cap reached: ${EXTENSION_COUNT} extensions applied (max ${MAX_EXTENSIONS})."
        fi
        warn "Max iterations ($MAX_ITERATIONS) reached."
        STATUS="max_iterations"
        return 1
    fi

    # Checkpoint audit: is there meaningful progress worth extending for?
    echo -e "\n  ${CYAN}${BOLD}▸ Checkpoint${RESET} — max iterations ($MAX_ITERATIONS) reached, evaluating progress..."

    local should_extend=false
    local extension_reason=""

    # Check 1: recent meaningful progress (not stuck)
    if [[ "${CONSECUTIVE_FAILURES:-0}" -lt 2 ]]; then
        # Check 2: agent hasn't signaled completion (if it did, guard_completion handles it)
        local last_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
        # <<<LOOP:FAIL>>> is treated as "no completion" here — we extend to give the agent
        # a chance to recover from whatever caused the failure signal.
        if [[ -f "$last_log" ]] && ! detect_gate_signal "$last_log" "LOOP" \
            'LOOP_COMPLETE' \
            '<<<LOOP:FAIL>>>'; then
            should_extend=true
            extension_reason="work in progress with recent progress"
        fi
    fi

    # Check 3: if quality gates or tests are failing, extend to let agent fix them
    if [[ "$TEST_PASSED" == "false" ]] || ! $QUALITY_GATE_PASSED; then
        should_extend=true
        extension_reason="quality gates or tests not yet passing"
    fi

    if $should_extend; then
        # Scale extension size by velocity — good progress earns more iterations
        local velocity_avg
        velocity_avg="$(compute_velocity_avg)"
        local effective_extension="$EXTENSION_SIZE"
        if [[ "$velocity_avg" -gt 20 ]]; then
            # High velocity: grant more iterations
            effective_extension=$(( EXTENSION_SIZE + 3 ))
        elif [[ "$velocity_avg" -lt 5 ]]; then
            # Low velocity: grant fewer iterations
            effective_extension=$(( EXTENSION_SIZE > 2 ? EXTENSION_SIZE - 2 : 1 ))
        fi
        EXTENSION_COUNT=$(( EXTENSION_COUNT + 1 ))
        MAX_ITERATIONS=$(( MAX_ITERATIONS + effective_extension ))
        echo -e "  ${GREEN}✓${RESET} Auto-extending: +${effective_extension} iterations (now ${MAX_ITERATIONS} max, extension ${EXTENSION_COUNT}/${MAX_EXTENSIONS})"
        echo -e "  ${DIM}Reason: ${extension_reason} | velocity: ~${velocity_avg} lines/iter${RESET}"
        return 0
    fi

    warn "Max iterations reached — no recent progress detected."
    STATUS="max_iterations"
    return 1
}

record_iteration_stuckness_data() {
    local exit_code="${1:-0}"
    [[ -z "$LOG_DIR" ]] && return 0
    local tracking_file="${STUCKNESS_TRACKING_FILE:-$LOG_DIR/stuckness-tracking.txt}"
    local diff_hash error_hash
    diff_hash=$(git -C "${PROJECT_ROOT:-.}" diff HEAD 2>/dev/null | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1) || echo "none")
    local error_log="${ARTIFACTS_DIR:-${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/pipeline-artifacts}/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        error_hash=$(tail -5 "$error_log" 2>/dev/null | sort -u | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1) || echo "none")
    else
        error_hash="none"
    fi
    echo "${diff_hash}|${error_hash}|${exit_code}" >> "$tracking_file"
}

detect_stuckness() {
    STUCKNESS_HINT=""
    STUCKNESS_SNAPSHOT=""
    local iteration="${ITERATION:-0}"
    local stuckness_signals=0
    # Subset of signals that indicate something is *actively wrong* (cycling on a real
    # diff, repeating errors, non-zero exit pattern, budget exhaustion without passing
    # tests). Signals 1 and 6 are *idle-style*: they also fire on done-and-idle runs
    # where the work is committed and the tree is clean. The dampening block at the
    # bottom uses this counter to distinguish "stuck" from "done-and-idle".
    local active_failure_signals=0
    local stuckness_reasons=()
    local tracking_file="${STUCKNESS_TRACKING_FILE:-$LOG_DIR/stuckness-tracking.txt}"
    local tracking_lines
    tracking_lines=$(wc -l < "$tracking_file" 2>/dev/null || true)
    tracking_lines="${tracking_lines:-0}"

    # MD5 of empty input — recorded by record_iteration_state when `git diff HEAD`
    # returns nothing (i.e. the working tree is clean). A run of these hashes means
    # "all work is committed and the tree is idle", which is the OPPOSITE of cycling
    # (which is "same uncommitted diff repeating"). Signal 2 / 2b must skip this case
    # so that completed work doesn't get flagged as stuck. Idle-while-passing is
    # already covered by Signal 6 ("no code changes in last iteration") combined
    # with the loop's TEST_PASSED gate.
    local _empty_diff_hash="d41d8cd98f00b204e9800998ecf8427e"

    # Signal 1: Text overlap (existing logic) — compare last 2 iteration logs
    if [[ "$iteration" -ge 3 ]]; then
        local log1="$LOG_DIR/iteration-$(( iteration - 1 )).log"
        local log2="$LOG_DIR/iteration-$(( iteration - 2 )).log"
        local log3="$LOG_DIR/iteration-$(( iteration - 3 )).log"

        if [[ -f "$log1" && -f "$log2" ]]; then
            local lines1 lines2 common total overlap_pct
            lines1=$(tail -50 "$log1" 2>/dev/null | grep -v '^$' | sort || true)
            lines2=$(tail -50 "$log2" 2>/dev/null | grep -v '^$' | sort || true)

            if [[ -n "$lines1" && -n "$lines2" ]]; then
                total=$(echo "$lines1" | wc -l | tr -d ' ')
                common=$(comm -12 <(echo "$lines1") <(echo "$lines2") 2>/dev/null | wc -l | tr -d ' ' || true)
                common="${common:-0}"
                if [[ "$total" -gt 0 ]]; then
                    overlap_pct=$(( common * 100 / total ))
                else
                    overlap_pct=0
                fi
                if [[ "${overlap_pct:-0}" -ge 90 ]]; then
                    stuckness_signals=$((stuckness_signals + 1))
                    stuckness_reasons+=("high text overlap (${overlap_pct}%) between iterations")
                fi
            fi
        fi
    fi

    # Signal 2: Git diff hash — last 5 iterations produced identical NON-EMPTY diffs.
    # Empty-diff hashes (clean tree) are intentionally excluded: they mean work is
    # committed, not that the agent is repeating the same uncommitted change.
    local _signal2_fired=false
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 5 ]]; then
        local last_five
        last_five=$(tail -5 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
        local unique_hashes
        unique_hashes=$(echo "$last_five" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
        local sole_hash
        sole_hash=$(echo "$last_five" | sort -u | grep -v '^$' | head -1)
        if [[ "$unique_hashes" -le 1 ]] && [[ -n "$last_five" ]] && [[ "$sole_hash" != "$_empty_diff_hash" ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            active_failure_signals=$((active_failure_signals + 1))
            stuckness_reasons+=("identical git diffs in last 5 iterations")
            _signal2_fired=true
        fi
    fi

    # Signal 2b: Explicit cycling detector — 4+ consecutive identical NON-EMPTY diffs.
    # Runs independently of Signal 2 to maintain monotonic detection: if 4+ identical diffs
    # are detected, it fires and keeps firing as sequences grow longer (5+, 6+, etc).
    # Skips empty-diff runs (clean tree = committed work, not cycling).
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 4 ]]; then
        local last_four
        last_four=$(tail -4 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
        local unique_four
        unique_four=$(echo "$last_four" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
        local count_four
        count_four=$(echo "$last_four" | grep -v '^$' | wc -l | tr -d ' ')
        local sole_four
        sole_four=$(echo "$last_four" | sort -u | grep -v '^$' | head -1)
        if [[ "$unique_four" -le 1 ]] && [[ "${count_four:-0}" -ge 4 ]] && [[ "$sole_four" != "$_empty_diff_hash" ]]; then
            stuckness_signals=$((stuckness_signals + 2))
            active_failure_signals=$((active_failure_signals + 2))
            stuckness_reasons+=("cycling: ${count_four} consecutive identical diffs (cycling detector)")
        fi
    fi

    # Signal 3: Error repetition — same error hash in last 3 iterations
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 3 ]]; then
        local last_three_errors
        last_three_errors=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f2 || true)
        local unique_error_hashes
        unique_error_hashes=$(echo "$last_three_errors" | sort -u | grep -v '^none$' | grep -v '^$' | wc -l | tr -d ' ')
        if [[ "$unique_error_hashes" -eq 1 ]] && [[ -n "$(echo "$last_three_errors" | grep -v '^none$')" ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            active_failure_signals=$((active_failure_signals + 1))
            stuckness_reasons+=("same error in last 3 iterations")
        fi
    fi

    # Signal 4: Same error repeating 3+ times (legacy check on error-log content)
    local error_log
    error_log="${ARTIFACTS_DIR:-$PROJECT_ROOT/.claude/pipeline-artifacts}/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_errors
        last_errors=$(tail -5 "$error_log" 2>/dev/null | jq -r '.error // .message // .error_hash // empty' 2>/dev/null | sort | uniq -c | sort -rn | head -1 || true)
        local repeat_count
        repeat_count=$(echo "$last_errors" | awk '{print $1}' 2>/dev/null || echo "0")
        if [[ "${repeat_count:-0}" -ge 3 ]]; then
            stuckness_signals=$((stuckness_signals + 1))
            active_failure_signals=$((active_failure_signals + 1))
            stuckness_reasons+=("same error repeated ${repeat_count} times")
        fi
    fi

    # Signal 5: Exit code pattern — last 3 iterations had same non-zero exit code
    if [[ -f "$tracking_file" ]] && [[ "$tracking_lines" -ge 3 ]]; then
        local last_three_exits
        last_three_exits=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f3 || true)
        local first_exit
        first_exit=$(echo "$last_three_exits" | head -1)
        if [[ "$first_exit" =~ ^[0-9]+$ ]] && [[ "$first_exit" -ne 0 ]]; then
            local all_same=true
            while IFS= read -r ex; do
                [[ "$ex" != "$first_exit" ]] && all_same=false
            done <<< "$last_three_exits"
            if [[ "$all_same" == true ]]; then
                stuckness_signals=$((stuckness_signals + 1))
                active_failure_signals=$((active_failure_signals + 1))
                stuckness_reasons+=("same non-zero exit code (${first_exit}) in last 3 iterations")
            fi
        fi
    fi

    # Signal 6: Git diff size — no or minimal code changes (existing)
    local diff_lines
    diff_lines=$(git -C "${PROJECT_ROOT:-.}" diff HEAD 2>/dev/null | wc -l | tr -d ' ' || true)
    diff_lines="${diff_lines:-0}"
    if [[ "${diff_lines:-0}" -lt 5 ]] && [[ "$iteration" -gt 2 ]]; then
        stuckness_signals=$((stuckness_signals + 1))
        stuckness_reasons+=("no code changes in last iteration")
    fi

    # Signal 7: Iteration budget — used >70% without passing tests
    local max_iter="${MAX_ITERATIONS:-20}"
    local progress_pct=0
    if [[ "$max_iter" -gt 0 ]]; then
        progress_pct=$(( iteration * 100 / max_iter ))
    fi
    if [[ "$progress_pct" -gt 70 ]] && [[ "${TEST_PASSED:-false}" != "true" ]]; then
        stuckness_signals=$((stuckness_signals + 1))
        active_failure_signals=$((active_failure_signals + 1))
        stuckness_reasons+=("used ${progress_pct}% of iteration budget without passing tests")
    fi

    # Done-and-idle escape hatch: when tests pass and no *active failure* signal fired
    # (cycling, error repetition, exit pattern, budget exhaustion), the only way to reach
    # 2+ signals is via Signals 1 + 6 — high text overlap on similar logs and a clean
    # tree. That is exactly what completed work looks like in the autonomous loop, not
    # stuckness. Reset signals to 0 in this case so the loop can declare LOOP_COMPLETE
    # without tripping the false-positive stuckness branch in the prompt builder.
    # Cycling protection (#324, #331) is preserved because Signals 2/2b/3/4/5/7 each
    # increment active_failure_signals — if any fires, this guard does not apply.
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "$active_failure_signals" -eq 0 ]] && [[ "$stuckness_signals" -ge 2 ]]; then
        stuckness_signals=0
        stuckness_reasons=()
    fi

    # Gate-aware dampening: only when code actually changed this iteration (diff_lines > 5).
    # Zero-diff iterations are handled by the done-and-idle escape hatch above when an
    # active failure signal is absent; when an active failure signal IS present, dampening
    # is intentionally withheld so #324 cycling protection still trips.
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "$stuckness_signals" -ge 2 ]]; then
        if [[ "${diff_lines:-0}" -gt 5 ]]; then
            if [[ "${AUDIT_RESULT:-}" == "pass" ]] || $QUALITY_GATE_PASSED 2>/dev/null; then
                stuckness_signals=$((stuckness_signals - 1))
            fi
        fi
    fi

    # Decision: 2+ signals = stuck
    if [[ "$stuckness_signals" -ge 2 ]]; then
        STUCKNESS_COUNT=$(( STUCKNESS_COUNT + 1 ))
        STUCKNESS_DIAGNOSIS="${stuckness_reasons[*]}"
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.stuckness_detected" "signals=$stuckness_signals" "count=$STUCKNESS_COUNT" "iteration=$iteration" "reasons=${stuckness_reasons[*]}"
        fi

        # Throttle: skip ruflo subprocesses when (signals, reasons) fingerprint
        # is unchanged from the last detection. The on-disk fingerprint in LOG_DIR
        # survives session restarts; both ruflo_store and ruflo_recall are gated
        # on it so neither re-spawns after a restart for an unchanged pattern.
        # Note: parallel --worktree pipelines each have their own LOG_DIR, so
        # each pipeline's throttle is independent — no cross-process locking needed.
        local _fp _prev_fp _fp_file="" _fp_new=false _ruflo_fired=false
        _fp=$(_stuckness_fingerprint "$stuckness_signals" "${stuckness_reasons[*]}")
        if [[ -n "${LOG_DIR:-}" ]]; then
            _fp_file="$LOG_DIR/.last-stuckness-fingerprint"
            if [[ -f "$_fp_file" ]]; then
                _prev_fp=$(cat "$_fp_file" 2>/dev/null || true)
            else
                _prev_fp=""
            fi
        else
            _prev_fp=""   # fail-open: missing LOG_DIR forces "differs" branch
        fi
        [[ "$_fp" != "$_prev_fp" ]] && _fp_new=true

        if "$_fp_new" && type ruflo_store >/dev/null 2>&1; then
            local _reasons_escaped="${stuckness_reasons[*]}"
            _reasons_escaped="${_reasons_escaped//\\/\\\\}"
            _reasons_escaped="${_reasons_escaped//\"/\\\"}"
            _reasons_escaped="${_reasons_escaped//$'\n'/\\n}"
            _reasons_escaped="${_reasons_escaped//$'\r'/\\r}"
            _reasons_escaped="${_reasons_escaped//$'\t'/\\t}"
            ruflo_store "stuckness-iter-${iteration}" \
                "{\"signals\":$stuckness_signals,\"reasons\":\"${_reasons_escaped}\",\"iteration\":$iteration}" \
                "learning-${REPO_HASH:-default}" "stuckness,loop,cycling" || true
            _ruflo_fired=true
        fi
        STUCKNESS_HINT="IMPORTANT: The loop appears stuck. Previous approaches have not worked. You MUST try a fundamentally different strategy. Reasons: ${stuckness_reasons[*]}"
        warn "Stuckness detected (${stuckness_signals} signals, count ${STUCKNESS_COUNT}): ${stuckness_reasons[*]}"

        local diff_summary=""
        local log1="$LOG_DIR/iteration-$(( iteration - 1 )).log"
        local log3="$LOG_DIR/iteration-$(( iteration - 3 )).log"
        if [[ -f "$log3" && -f "$log1" ]]; then
            diff_summary=$(diff <(tail -30 "$log3" 2>/dev/null) <(tail -30 "$log1" 2>/dev/null) 2>/dev/null | head -10 || true)
        fi

        # T2.2: Compose structured STUCKNESS_SNAPSHOT with richer telemetry (file edit counts,
        # failing tests, unresolved findings) so the agent has actionable context.
        local _snap_edited_files=""
        local _snap_failing_tests=""
        local _snap_unresolved=""
        if [[ -f "$log1" ]]; then
            _snap_edited_files=$(grep -oE '^[[:space:]]*(Edit|Write|Create)[[:space:]]+[^[:space:]]+' "$log1" 2>/dev/null \
                | sed 's/^[[:space:]]*//' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /' || true)
        fi
        if [[ -f "${ERROR_SUMMARY_FILE:-/dev/null}" ]]; then
            _snap_failing_tests=$(jq -r '.failing_tests[]? // empty' "${ERROR_SUMMARY_FILE}" 2>/dev/null \
                | head -5 | sed 's/^/    /' || true)
        fi
        if [[ -f "${ARTIFACTS_DIR:-/dev/null}/review.findings.json" ]]; then
            _snap_unresolved=$(jq -r '.findings[]? | select(.resolved != true) | .summary // empty' \
                "${ARTIFACTS_DIR}/review.findings.json" 2>/dev/null | head -3 | sed 's/^/    /' || true)
        fi

        STUCKNESS_SNAPSHOT="STUCKNESS SIGNALS DETECTED (${stuckness_reasons[*]}):
${_snap_edited_files:+  Files touched most in last iterations:
$_snap_edited_files
}${_snap_failing_tests:+  Tests still failing:
$_snap_failing_tests
}${_snap_unresolved:+  Findings unresolved across cycles:
$_snap_unresolved
}  You appear to be reverting between two states. Review your diff against HEAD~3 before continuing."

        emit_event "loop.stuckness_snapshot" \
            "signals=${stuckness_signals}" \
            "reasons=${stuckness_reasons[*]}" \
            "iteration=${iteration}" 2>/dev/null || true

        local alternatives=""
        if type memory_inject_context >/dev/null 2>&1; then
            alternatives=$(memory_inject_context "build" 2>/dev/null | grep -i "fix:" | head -3 || true)
        fi

        local ruflo_patterns=""
        if [[ "$_fp" == "$_STUCKNESS_RECALL_CACHE_FP" ]] && [[ "$_STUCKNESS_RECALL_CACHE_VALID" == "true" ]]; then
            ruflo_patterns="$_STUCKNESS_RECALL_CACHE"
        elif "$_fp_new" && type ruflo_recall >/dev/null 2>&1; then
            ruflo_patterns=$(ruflo_recall "loop cycling identical diff stuckness" \
                "learning-${REPO_HASH:-default}" 2>/dev/null || true)
            _STUCKNESS_RECALL_CACHE="$ruflo_patterns"
            _STUCKNESS_RECALL_CACHE_FP="$_fp"
            _STUCKNESS_RECALL_CACHE_VALID=true
            _ruflo_fired=true
        fi

        # Atomically persist fingerprint after ruflo subprocesses were attempted.
        # Gating on _ruflo_fired prevents a transient failure from locking in a
        # fingerprint that would suppress retries on the next iteration.
        if "$_ruflo_fired" && [[ -n "$_fp_file" ]]; then
            local _tmp="${_fp_file}.tmp.$$"
            if printf '%s\n' "$_fp" > "$_tmp" 2>/dev/null; then
                mv "$_tmp" "$_fp_file" 2>/dev/null || rm -f "$_tmp"
            else
                rm -f "$_tmp" 2>/dev/null || true
            fi
        fi

        cat <<STUCK_SECTION
## Stuckness Detected
${STUCKNESS_HINT}

${STUCKNESS_SNAPSHOT}

${diff_summary:+Changes between recent iterations:
$diff_summary
}
${alternatives:+Consider these alternative approaches from past fixes:
$alternatives
}
${ruflo_patterns:+Ruflo recalled similar patterns from past runs:
$ruflo_patterns
}
Try a fundamentally different approach:
- Break the problem into smaller steps
- Look for an entirely different implementation strategy
- Check if there's a dependency or configuration issue blocking progress
- Read error messages more carefully — the root cause may differ from your assumption
STUCK_SECTION
        return 0
    fi

    return 1
}
