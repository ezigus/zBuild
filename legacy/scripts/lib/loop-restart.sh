#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_RESTART_LOADED:-}" ]] && return 0
_LOOP_RESTART_LOADED=1

# Source goal sanitization helper (strips synthesized sections from goals)
# shellcheck source=goal-sanitize.sh
[[ -f "$(dirname "${BASH_SOURCE[0]}")/goal-sanitize.sh" ]] && source "$(dirname "${BASH_SOURCE[0]}")/goal-sanitize.sh"

# ─── State Management ────────────────────────────────────────────────────────

initialize_state() {
    ITERATION=0
    CONSECUTIVE_FAILURES=0
    TOTAL_COMMITS=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"
    LOG_ENTRIES=""

    # Record loop start epoch for time-budget guard (check_time_budget in loop-convergence.sh)
    LOOP_START_EPOCH="$(now_epoch 2>/dev/null || echo 0)"

    # Record starting commit for cumulative diff in quality gates
    LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"

    write_state
}

resume_state() {
    # Known status values in loop-state.md (the `status:` YAML field):
    #   running            - loop is in progress
    #   complete           - loop finished successfully (LOOP:PASS accepted)
    #   stuck              - loop terminated because no progress was being made (no resume)
    #   circuit_breaker    - too many consecutive failures (terminal)
    #   max_iterations     - hit max-iterations cap (resumable with --max-iterations)
    #   interrupted        - user-interrupted (resumable)
    #   error              - generic error (terminal unless re-tried)
    #   budget_exhausted   - out of budget (terminal)
    # Resume policy: only `complete` and `stuck` short-circuit resume here; every
    # other value falls through to STATUS="running" and re-enters the loop.
    #
    # 9-row audit table — every reader of the `status:` field in loop-state.md
    # (this comment is the canonical equivalent of the audit table in PR #456):
    #
    # # | File:Line                              | What it does                       | Behavior on `stuck`            | Action in this PR
    # 1 | scripts/lib/loop-restart.sh:65         | YAML parser → STATUS variable      | Permissive; accepts `stuck`    | None — already correct
    # 2 | scripts/lib/loop-restart.sh:127        | Terminal check (only `complete` exits) | Short-circuit before fallthrough | This branch — explicit stuck arm
    # 3 | scripts/lib/loop-restart.sh:~145       | Unconditional STATUS="running" reset | Overwrites stuck if reached  | Now unreachable for stuck (early exit at #2)
    # 4 | scripts/lib/loop-restart.sh:write_state| write_state emits STATUS verbatim  | Round-trips `stuck` correctly  | None — already correct
    # 5 | scripts/sw-loop.sh:~1961               | case "$STATUS" in show_summary()   | Falls through to dim default   | Add explicit `stuck)` arm with red ✗
    # 6 | scripts/sw-loop.sh:~1978               | Uppercase `LOOP $STATUS` banner    | Renders `LOOP STUCK` legibly   | None
    # 7 | scripts/sw-loop.sh:~2830               | Sets STATUS="stuck_restart"        | Different value; not terminal  | None — must NOT conflate with `stuck`; never written to state file (in-memory only)
    # 8 | scripts/sw-loop.sh:~2854               | if [[ "$STATUS" == "complete" ]]   | False for stuck — correct      | None
    # 9 | scripts/sw-checkpoint.sh:~111          | Reads SW_LOOP_STATUS env           | Pass-through, no branching     | None
    #
    # Three of nine sites need code changes: #2, #3 (collateral), #5. Six are call-outs only.
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No state file found at $STATE_FILE"
        echo -e "  Start a new loop instead: ${DIM}shipwright loop \"<goal>\"${RESET}"
        exit 1
    fi

    info "Resuming from $STATE_FILE"

    # Status field values written by write_state() / set throughout the loop:
    #   running          — active iteration in progress (resumable)
    #   complete         — <<<LOOP:PASS>>> accepted (terminal)
    #   stuck            — no progress for too many iterations (terminal, NOT resumable)
    #   circuit_breaker  — too many consecutive failures (terminal)
    #   max_iterations   — hit MAX_ITERATIONS (resumable with --max-iterations bump)
    #   interrupted      — user Ctrl-C (resumable)
    #   error            — fatal CLI/API error (terminal)
    #   budget_exhausted — daily token budget hit (terminal)
    # Resume policy below: explicit terminal-status checks refuse resume; everything
    # else falls through to STATUS="running" reset on line 134.

    # Save CLI values before parsing state (CLI takes precedence)
    local cli_max_iterations="$MAX_ITERATIONS"

    # Parse YAML front matter
    local in_frontmatter=false
    local _has_original_goal=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then
                break
            else
                in_frontmatter=true
                continue
            fi
        fi
        if $in_frontmatter; then
            case "$line" in
                goal:*)
                    if [[ -z "$GOAL" ]]; then
                        local _g _s=$'\001'
                        _g="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')"
                        _g="${_g//\\\\/$_s}"
                        _g="${_g//\\n/$'\n'}"
                        GOAL="${_g//$_s/\\}"
                    fi ;;
                original_goal:*)
                    local _og _s2=$'\001'
                    _og="$(echo "${line#original_goal:}" | sed 's/^ *"//;s/" *$//')"
                    _og="${_og//\\\\/$_s2}"
                    _og="${_og//\\n/$'\n'}"
                    ORIGINAL_GOAL="${_og//$_s2/\\}"
                    _has_original_goal=true ;;
                iteration:*)     ITERATION="$(echo "${line#iteration:}" | tr -d ' ')" ;;
                max_iterations:*) MAX_ITERATIONS="$(echo "${line#max_iterations:}" | tr -d ' ')" ;;
                status:*)        STATUS="$(echo "${line#status:}" | tr -d ' ')" ;;
                test_cmd:*)      [[ -z "$TEST_CMD" ]] && TEST_CMD="$(echo "${line#test_cmd:}" | sed 's/^ *"//;s/" *$//')" ;;
                model:*)         MODEL="$(echo "${line#model:}" | tr -d ' ')" ;;
                agents:*)        AGENTS="$(echo "${line#agents:}" | tr -d ' ')" ;;
                consecutive_failures:*) CONSECUTIVE_FAILURES="$(echo "${line#consecutive_failures:}" | tr -d ' ')" ;;
                total_commits:*) TOTAL_COMMITS="$(echo "${line#total_commits:}" | tr -d ' ')" ;;
                audit_enabled:*)         AUDIT_ENABLED="$(echo "${line#audit_enabled:}" | tr -d ' ')" ;;
                audit_agent_enabled:*)   AUDIT_AGENT_ENABLED="$(echo "${line#audit_agent_enabled:}" | tr -d ' ')" ;;
                quality_gates_enabled:*) QUALITY_GATES_ENABLED="$(echo "${line#quality_gates_enabled:}" | tr -d ' ')" ;;
                dod_file:*)              DOD_FILE="$(echo "${line#dod_file:}" | sed 's/^ *"//;s/" *$//')" ;;
                auto_extend:*)           AUTO_EXTEND="$(echo "${line#auto_extend:}" | tr -d ' ')" ;;
                extension_count:*)       EXTENSION_COUNT="$(echo "${line#extension_count:}" | tr -d ' ')" ;;
                max_extensions:*)        MAX_EXTENSIONS="$(echo "${line#max_extensions:}" | tr -d ' ')" ;;
                dod_diff_max_lines:*)    DOD_DIFF_MAX_LINES="$(echo "${line#dod_diff_max_lines:}" | tr -d ' ')" ;;
                holistic_diff_max_lines:*) HOLISTIC_DIFF_MAX_LINES="$(echo "${line#holistic_diff_max_lines:}" | tr -d ' ')" ;;
            esac
        fi
    done < "$STATE_FILE"

    if $_has_original_goal; then
        # New state file: original_goal field was present.
        # Apply unified sentinel stripping to BOTH fields — defense in depth.
        # If ORIGINAL_GOAL somehow has synthesis pollution, clean it.
        if declare -f _strip_synthesized_sections >/dev/null 2>&1; then
            ORIGINAL_GOAL="$(_strip_synthesized_sections "$ORIGINAL_GOAL")"
            GOAL="${GOAL:-$ORIGINAL_GOAL}"
            GOAL="$(_strip_synthesized_sections "$GOAL")"
        fi
    else
        # Legacy state file: no original_goal field — apply backward-compat sentinel stripping.
        # Uses the unified helper if available, fallback to inline sentinels.
        if declare -f _strip_synthesized_sections >/dev/null 2>&1; then
            GOAL="$(_strip_synthesized_sections "$GOAL")"
        else
            # Fallback (if goal-sanitize.sh failed to load) — inline legacy sentinels only
            if [[ "$GOAL" == *$'\n\nBLOCKING ISSUES'* ]];              then GOAL="${GOAL%%$'\n\nBLOCKING ISSUES'*}";              fi
            if [[ "$GOAL" == *$'\n\nIMPORTANT — Previous build'* ]];   then GOAL="${GOAL%%$'\n\nIMPORTANT — Previous build'*}";   fi
            if [[ "$GOAL" == *$'\n\nIMPORTANT — Code review'* ]];      then GOAL="${GOAL%%$'\n\nIMPORTANT — Code review'*}";      fi
            if [[ "$GOAL" == *$'\n\nIMPORTANT — Architecture'* ]];     then GOAL="${GOAL%%$'\n\nIMPORTANT — Architecture'*}";     fi
            if [[ "$GOAL" == *$'\n\nIMPORTANT — Compound quality'* ]]; then GOAL="${GOAL%%$'\n\nIMPORTANT — Compound quality'*}"; fi
            if [[ "$GOAL" == *$'\n\nHUMAN FEEDBACK'* ]];               then GOAL="${GOAL%%$'\n\nHUMAN FEEDBACK'*}";               fi
            if [[ "$GOAL" == *$'\n\n## Previous Session Context'* ]];  then GOAL="${GOAL%%$'\n\n## Previous Session Context'*}";  fi
            # KNOWN FIX is prepended — strip from start through first blank line
            if [[ "$GOAL" == "KNOWN FIX (from past success):"* ]];     then GOAL="${GOAL#*$'\n\n'}";                              fi
        fi
        ORIGINAL_GOAL="${ORIGINAL_GOAL:-$GOAL}"
    fi

    # CLI --max-iterations overrides state file
    if $MAX_ITERATIONS_EXPLICIT; then
        MAX_ITERATIONS="$cli_max_iterations"
    fi

    # Extract the log section (everything after ## Log)
    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$STATUS" == "complete" ]]; then
        warn "Previous loop completed. Start a new one or edit the state file."
        exit 0
    fi

    # Stuck is a terminal state — the loop made no progress for too many iterations
    # and write_state() will eventually emit it. Refuse to resume so we don't re-enter
    # the same OOM/no-progress cycle. User must investigate, fix, then start a new loop.
    # exit 2 (not 0) so callers and CI can distinguish stuck from clean completion.
    if [[ "$STATUS" == "stuck" ]]; then
        warn "Previous loop terminated as stuck (no progress detected)."
        info "  Refusing to resume; investigate before restarting:"
        info "    ${DIM}shipwright memory show${RESET}    # captured failure patterns"
        info "    ${DIM}cat $STATE_FILE${RESET}          # review loop state"
        info "    ${DIM}shipwright loop \"<new goal>\"${RESET}  # start fresh after diagnosis"
        exit 2
    fi

    # Reset circuit breaker on resume
    CONSECUTIVE_FAILURES=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"

    # Set starting commit for cumulative diff (approximate: use earliest tracked commit)
    if [[ -z "${LOOP_START_COMMIT:-}" ]]; then
        LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 || echo "")"
    fi

    # If we hit max iterations before, warn user to extend
    if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]] && ! $MAX_ITERATIONS_EXPLICIT; then
        warn "Previous run stopped at iteration $ITERATION/$MAX_ITERATIONS."
        echo -e "  Extend with: ${DIM}shipwright loop --resume --max-iterations $(( MAX_ITERATIONS + 10 ))${RESET}"
        exit 0
    fi

    # Restore Claude context for meaningful resume (source so exports persist to this shell)
    if [[ -f "$SCRIPT_DIR/sw-checkpoint.sh" ]] && [[ -d "${PROJECT_ROOT:-}" ]]; then
        source "$SCRIPT_DIR/sw-checkpoint.sh"
        local _orig_pwd="$PWD"
        cd "$PROJECT_ROOT" 2>/dev/null || true
        if checkpoint_restore_context "build" 2>/dev/null; then
            RESUMED_FROM_ITERATION="${RESTORED_ITERATION:-}"
            RESUMED_MODIFIED="${RESTORED_MODIFIED:-}"
            RESUMED_FINDINGS="${RESTORED_FINDINGS:-}"
            RESUMED_TEST_OUTPUT="${RESTORED_TEST_OUTPUT:-}"
            [[ -n "${RESTORED_ITERATION:-}" && "${RESTORED_ITERATION:-0}" -gt 0 ]] && info "Restored context from iteration ${RESTORED_ITERATION}"
        fi
        cd "$_orig_pwd" 2>/dev/null || true
    fi

    success "Resumed: iteration $ITERATION/$MAX_ITERATIONS"
}

write_state() {
    local tmp_state="${STATE_FILE}.tmp.$$"
    # Always persist ORIGINAL_GOAL (clean) to both goal: and original_goal: fields.
    # Layer A+B ensure GOAL is clean before this is called in normal operation, but
    # bootstrap here for the --issue pipeline flow where intake calls write_state
    # with GOAL set from the issue title and ORIGINAL_GOAL still empty.
    if [[ -z "${ORIGINAL_GOAL:-}" && -n "${GOAL:-}" ]]; then
        ORIGINAL_GOAL="$GOAL"
    fi
    local _orig_goal_esc="${ORIGINAL_GOAL//\\/\\\\}"
    _orig_goal_esc="${_orig_goal_esc//$'\n'/\\n}"
    # Use printf instead of heredoc to avoid delimiter injection from GOAL
    {
        printf -- '---\n'
        printf 'goal: "%s"\n' "$_orig_goal_esc"
        printf 'original_goal: "%s"\n' "$_orig_goal_esc"
        printf 'iteration: %s\n' "$ITERATION"
        printf 'max_iterations: %s\n' "$MAX_ITERATIONS"
        printf 'status: %s\n' "$STATUS"
        printf 'test_cmd: "%s"\n' "$TEST_CMD"
        printf 'model: %s\n' "$MODEL"
        printf 'agents: %s\n' "$AGENTS"
        printf 'started_at: %s\n' "$(now_iso)"
        printf 'last_iteration_at: %s\n' "$(now_iso)"
        printf 'consecutive_failures: %s\n' "$CONSECUTIVE_FAILURES"
        printf 'total_commits: %s\n' "$TOTAL_COMMITS"
        printf 'audit_enabled: %s\n' "$AUDIT_ENABLED"
        printf 'audit_agent_enabled: %s\n' "$AUDIT_AGENT_ENABLED"
        printf 'quality_gates_enabled: %s\n' "$QUALITY_GATES_ENABLED"
        printf 'dod_file: "%s"\n' "$DOD_FILE"
        printf 'auto_extend: %s\n' "$AUTO_EXTEND"
        printf 'extension_count: %s\n' "$EXTENSION_COUNT"
        printf 'max_extensions: %s\n' "$MAX_EXTENSIONS"
        printf 'dod_diff_max_lines: %s\n' "$DOD_DIFF_MAX_LINES"
        printf 'holistic_diff_max_lines: %s\n' "$HOLISTIC_DIFF_MAX_LINES"
        printf -- '---\n\n'
        printf '## Log\n'
        printf '%s\n' "$LOG_ENTRIES"
    } > "$tmp_state"
    if ! mv "$tmp_state" "$STATE_FILE" 2>/dev/null; then
        warn "Failed to write state file: $STATE_FILE"
    fi
}

check_fatal_error() {
    local log_file="$1"
    local cli_exit_code="${2:-0}"
    local err_file="${3:-}"
    [[ -f "$log_file" ]] || return 1

    # Known fatal error patterns from Claude CLI / Anthropic API
    local fatal_patterns="Invalid API key|invalid_api_key|authentication_error|API key expired"
    fatal_patterns="${fatal_patterns}|rate_limit_error|overloaded_error|billing"
    fatal_patterns="${fatal_patterns}|Could not resolve host|connection refused|ECONNREFUSED"
    fatal_patterns="${fatal_patterns}|ANTHROPIC_API_KEY.*not set|No API key"
    # Session/usage limit patterns — treated as fatal (not transient retryable errors)
    fatal_patterns="${fatal_patterns}|Usage limit reached|out of credits|credit balance|session.*limit|usage.*limit"
    fatal_patterns="${fatal_patterns}|claude\.ai/usage|Your credit balance is|human turn limit"

    # Search stdout log; also search stderr file when provided and non-empty.
    local _matched=false
    if grep -qiE "$fatal_patterns" "$log_file" 2>/dev/null; then
        _matched=true
    elif [[ -n "$err_file" && -s "$err_file" ]] && grep -qiE "$fatal_patterns" "$err_file" 2>/dev/null; then
        _matched=true
    fi

    if [[ "$_matched" == "true" ]]; then
        local match
        if grep -qiE "$fatal_patterns" "$log_file" 2>/dev/null; then
            match=$(grep -iE "$fatal_patterns" "$log_file" 2>/dev/null | head -1 | cut -c1-120)
        else
            match=$(grep -iE "$fatal_patterns" "$err_file" 2>/dev/null | head -1 | cut -c1-120)
        fi
        error "Fatal CLI error: $match"
        return 0  # fatal error detected — abort loop
    fi

    # Non-zero exit + tiny output = likely CLI crash
    if [[ "$cli_exit_code" -ne 0 ]]; then
        local line_count
        line_count=$(grep -cv '^$' "$log_file" 2>/dev/null || true)
        line_count="${line_count:-0}"
        if [[ "$line_count" -lt 3 ]]; then
            local content
            content=$(head -3 "$log_file" 2>/dev/null | cut -c1-120)
            error "CLI exited $cli_exit_code with minimal output: $content"
            return 1  # not conclusively fatal — let circuit breaker handle retries
        fi
    fi

    return 1  # no fatal error
}
