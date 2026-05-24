#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_ITERATION_LOADED:-}" ]] && return 0
_LOOP_ITERATION_LOADED=1

# ─── Task Progress ───────────────────────────────────────────────────────────

# Produce a dynamic task list section each iteration.
# On iteration 1 (no cumulative diff yet): show the raw checklist as guidance.
# On iteration 2+: annotate each task with [x] when the cumulative diff touches
# a keyword inferred from changed file basenames that appears in the task
# description, giving the agent an approximate view of completed vs remaining work.
compose_task_section() {
    [[ -z "${TASKS_FILE:-}" || ! -f "$TASKS_FILE" ]] && return 0

    local changed_files=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        changed_files="$(git -C "${PROJECT_ROOT:-.}" diff --name-only "${LOOP_START_COMMIT}..HEAD" -- . $(_git_excluded_pathspecs 2>/dev/null) 2>/dev/null || true)"
    fi

    # No commits yet — show raw list as initial guidance
    if [[ -z "$changed_files" ]]; then
        cat "$TASKS_FILE"
        return 0
    fi

    # Build a flat keyword list from changed file basenames (stem only, 4+ chars)
    local keywords=""
    while IFS= read -r cf; do
        local stem
        stem="$(basename "$cf" 2>/dev/null)"
        stem="${stem%.*}"
        [[ ${#stem} -ge 4 ]] && keywords="${keywords} ${stem}"
    done <<< "$changed_files"

    # Annotate task lines; pass non-task lines through unchanged
    local completed=0 total=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-\ \[\ \] ]]; then
            total=$((total + 1))
            local task_text="${line#*\[ \] }"
            local matched=false
            # Case-insensitive substring match — Bash 3.2 compatible (no ${var,,})
            local kw task_text_lc kw_lc
            task_text_lc="$(printf '%s' "$task_text" | tr '[:upper:]' '[:lower:]')"
            for kw in $keywords; do
                kw_lc="$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')"
                case "$task_text_lc" in
                    *"$kw_lc"*) matched=true; break ;;
                esac
            done
            if [[ "$matched" == "true" ]]; then
                # Replace [ ] with [x] — Bash 3.2 compatible substitution
                echo "${line/- [ ]/- [x]}"
                completed=$((completed + 1))
            else
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$TASKS_FILE"

    if [[ "$total" -gt 0 ]]; then
        echo ""
        echo "(${completed}/${total} tasks inferred complete from committed changes — verify and check off any missed)"
    fi
}

# ─── Prompt Composition ──────────────────────────────────────────────────────

manage_context_window() {
    local prompt="$1"
    local budget="${CONTEXT_BUDGET_CHARS:-200000}"
    local current_len=${#prompt}

    # Read trimming tunables from config (env > daemon-config > policy > defaults.json)
    local trim_memory_chars trim_git_entries trim_hotspot_files trim_test_lines
    trim_memory_chars=$(_config_get_int "loop.context_trim_memory_chars" 20000 2>/dev/null || echo 20000)
    trim_git_entries=$(_config_get_int "loop.context_trim_git_entries" 10 2>/dev/null || echo 10)
    trim_hotspot_files=$(_config_get_int "loop.context_trim_hotspot_files" 5 2>/dev/null || echo 5)
    trim_test_lines=$(_config_get_int "loop.context_trim_test_lines" 50 2>/dev/null || echo 50)

    if [[ "$current_len" -le "$budget" ]]; then
        echo "$prompt"
        return
    fi

    # Over budget — progressively trim sections (least important first)
    local trimmed="$prompt"

    # 1. Trim DORA/Performance baselines (least critical for code generation)
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk '/^## Performance Baselines/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')
    fi

    # 2. Trim file hotspots to top N
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_hotspot_files" '/## File Hotspots/{p=1; c=0} p && /^- /{c++; if(c>max) next} {print}')
    fi

    # 3. Trim git log to last N entries
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_git_entries" '/## Recent Git Activity/{p=1; c=0} p && /^[a-f0-9]/{c++; if(c>max) next} {print}')
    fi

    # 4. Truncate memory context to first N chars
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_memory_chars" '
            /## Memory Context/{mem=1; skip_rest=0; chars=0; print; next}
            mem && /^## [^#]/{mem=0; print; next}
            mem{chars+=length($0)+1; if(chars>max){print "... (memory truncated for context budget)"; skip_rest=1; mem=0; next}}
            skip_rest && /^## [^#]/{skip_rest=0; print; next}
            skip_rest{next}
            {print}
        ')
    fi

    # 5. Truncate test output to last N lines
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_test_lines" '
            /## Test Results/{found=1; buf=""; print; next}
            found && /^## [^#]/{found=0; n=split(buf,arr,"\n"); start=(n>max)?(n-max+1):1; for(i=start;i<=n;i++) if(arr[i]!="") print arr[i]; print; next}
            found{buf=buf $0 "\n"; next}
            {print}
        ')
    fi

    # 6. Last resort: hard truncate with notice
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed="${trimmed:0:$budget}

... [CONTEXT TRUNCATED: prompt exceeded ${budget} char budget. Focus on the goal and most recent errors.]"
    fi

    # Log the trimming
    local final_len=${#trimmed}
    if [[ "$final_len" -lt "$current_len" ]]; then
        warn "Context trimmed from ${current_len} to ${final_len} chars (budget: ${budget})"
        emit_event "loop.context_trimmed" "original=$current_len" "trimmed=$final_len" "budget=$budget" 2>/dev/null || true
    fi

    echo "$trimmed"
}

compose_prompt() {
    # Iteration-aware context: full orientation on iter 1, session restart, or resume.
    # On iter 2+, static sections (pipeline context, memory base, discovery, dora,
    # intelligence hotspots) are skipped — the agent's work product (git, tests, tasks)
    # already reflects that context.
    local _needs_full_context=false
    if [[ "${ITERATION:-1}" -eq 1 \
       || "${SESSION_RESTART:-false}" == "true" \
       || -n "${RESUMED_FROM_ITERATION:-}" ]]; then
        _needs_full_context=true
    fi

    local recent_log
    if [[ -n "$LOG_ENTRIES" ]]; then
        recent_log="(Previous iterations — REFERENCE ONLY. This work is done. Do not re-execute.)
$(echo "$LOG_ENTRIES" | tail -15)"
    else
        recent_log="(first iteration — no previous progress)"
    fi

    # Deterministic record of work completed this pipeline — replaces heuristic tail scraping.
    # Only on iter 2+ (iter 1 has no commits yet).
    # Guard: on resume, LOOP_START_COMMIT may fall back to the repo root commit (loop-restart.sh:196-198)
    # when the original start SHA was not persisted in state. Cap at MAX_ITERATIONS commits so a stale
    # root-commit start does not dump all branch history as "already done" work.
    local recent_commits_section=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && [[ "${ITERATION:-1}" -gt 1 ]]; then
        local _commits
        _commits="$(git -C "$PROJECT_ROOT" log --format='%h %s' "${LOOP_START_COMMIT}..HEAD" \
            2>/dev/null | head -10 || true)"
        local _commit_count
        _commit_count=$(echo "$_commits" | grep -c . 2>/dev/null || echo 0)
        if [[ -n "$_commits" ]] && [[ "${_commit_count:-0}" -le "${MAX_ITERATIONS:-10}" ]]; then
            recent_commits_section="## Commits This Pipeline (ground truth — work that is done)
${_commits}

"
        fi
    fi

    local git_log
    git_log="$(git_recent_log)"

    # Structured error context (machine-readable)
    local error_summary_section=""
    local error_json="$LOG_DIR/error-summary.json"
    if [[ -f "$error_json" ]]; then
        local err_count err_lines
        err_count=$(jq -r '.error_count // 0' "$error_json" 2>/dev/null || echo "0")
        err_lines=$(jq -r '.error_lines[]? // empty' "$error_json" 2>/dev/null | head -10 || true)
        if [[ "$err_count" -gt 0 ]] && [[ -n "$err_lines" ]]; then
            error_summary_section="## Structured Error Summary (${err_count} errors detected)
${err_lines}

Fix these specific errors. Each line above is one distinct error from the test output."
        fi
    fi

    local test_section
    if [[ -z "$TEST_CMD" ]]; then
        test_section="No test command configured."
    elif [[ -z "$TEST_PASSED" ]]; then
        test_section="No test results yet (first iteration). Test command: $TEST_CMD"
    elif $TEST_PASSED; then
        if ! $_needs_full_context; then
            # Iter 2+: tests pass — the relevant signal is gate feedback, not 60 lines of checkmarks.
            local _test_summary
            _test_summary="$(echo "$TEST_OUTPUT" | grep -E 'pass|All [0-9]+ tests passed' | tail -3 || true)"
            test_section="TESTS PASSED.
${_test_summary:-(see iteration-$((ITERATION - 1)).log for full output)}"
        else
            test_section="$TEST_OUTPUT"
        fi
    elif ! $_needs_full_context && [[ -n "$error_summary_section" ]]; then
        # Iter 2+: structured errors available — demote full output, primary signal is the summary below
        test_section="TESTS FAILED — see Structured Error Summary below for specific errors.

Last 30 lines of test output:
$(echo "$TEST_OUTPUT" | tail -30)"
    else
        test_section="TESTS FAILED — fix these before proceeding:
$TEST_OUTPUT"
    fi

    # Build audit sections (captured before heredoc to avoid nested heredoc issues)
    local audit_section
    audit_section="$(compose_audit_section)"
    local audit_feedback_section
    audit_feedback_section="$(compose_audit_feedback_section)"
    local holistic_feedback_section
    holistic_feedback_section="$(compose_holistic_feedback_section)"
    local quality_gate_detail_section
    quality_gate_detail_section="$(compose_quality_gate_detail_section)"
    local gate_findings_section
    gate_findings_section="$(compose_gate_findings_section)"
    local rejection_notice_section
    rejection_notice_section="$(compose_rejection_notice_section)"

    # Zero-progress notice: fire when the previous iteration produced no new commits
    # AND the quality gate is still failing. Without this, the agent reads passing
    # tests + the same gate feedback and silently exits in seconds, making no changes.
    local zero_progress_notice=""
    if [[ "${PREV_NEW_COMMITS:-0}" -eq 0 ]] \
       && { [[ "${QUALITY_GATE_PASSED:-true}" == "false" ]] || $COMPLETION_REJECTED; }; then
        zero_progress_notice="
## Zero Progress Detected (IMPORTANT)
Your previous iteration made NO new commits. The working tree is identical to before.
Quality gates are still failing with the feedback shown above. You MUST either:
  (a) make concrete code changes and commit them, OR
  (b) state explicitly why the quality-gate feedback is incorrect, citing
      specific file:line evidence — do not silently exit.
Declaring LOOP_COMPLETE or exiting without committing code changes will not satisfy
the holistic gate and will count toward the circuit-breaker failure limit."
    fi

    # Memory context injection — base memory only on iter 1 / restart / resume
    local memory_section=""
    if $_needs_full_context; then
        if type memory_inject_context >/dev/null 2>&1; then
            memory_section="$(memory_inject_context "build" 2>/dev/null || true)"
        elif [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
            memory_section="$("$SCRIPT_DIR/sw-memory.sh" inject build 2>/dev/null || true)"
        fi
    fi

    # Append mid-loop memory refresh if available — always inject (per-iteration learning)
    local memory_refresh_file="$LOG_DIR/memory-refresh-$(( ITERATION - 1 )).txt"
    if [[ -f "$memory_refresh_file" ]]; then
        memory_section="${memory_section}

## Fresh Context (from iteration $(( ITERATION - 1 )) analysis)
$(cat "$memory_refresh_file")"
    fi

    # Cross-pipeline discovery injection (learnings from other pipeline runs)
    local discovery_section=""
    if $_needs_full_context; then
        if type inject_discoveries >/dev/null 2>&1; then
            local disc_output
            disc_output="$(inject_discoveries "${GOAL:-}" 2>/dev/null | head -10 || true)"
            if [[ -n "$disc_output" ]]; then
                discovery_section="$disc_output"
            fi
        fi
    fi

    # DORA baselines for context
    local dora_section=""
    if $_needs_full_context; then
        if type memory_get_dora_baseline >/dev/null 2>&1; then
            local dora_json
            dora_json="$(memory_get_dora_baseline 7 2>/dev/null || echo "{}")"
            local dora_total
            dora_total=$(echo "$dora_json" | jq -r '.total // 0' 2>/dev/null || echo "0")
            if [[ "$dora_total" -gt 0 ]]; then
                local dora_df dora_cfr
                dora_df=$(echo "$dora_json" | jq -r '.deploy_freq // 0' 2>/dev/null || echo "0")
                dora_cfr=$(echo "$dora_json" | jq -r '.cfr // 0' 2>/dev/null || echo "0")
                dora_section="## Performance Baselines (Last 7 Days)
- Deploy frequency: ${dora_df}/week
- Change failure rate: ${dora_cfr}%
- Total pipeline runs: ${dora_total}"
            fi
        fi
    fi

    # GitHub intelligence context — static parts only on iter 1 / restart / resume
    local intelligence_section=""
    if $_needs_full_context && [[ "${NO_GITHUB:-}" != "true" ]]; then
        # File hotspots — top 5 most-changed files
        if type gh_file_change_frequency >/dev/null 2>&1; then
            local hotspots
            hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
            if [[ -n "$hotspots" ]]; then
                intelligence_section="${intelligence_section}
## File Hotspots (most frequently changed)
${hotspots}"
            fi
        fi

        # CODEOWNERS context
        if type gh_codeowners >/dev/null 2>&1; then
            local owners
            owners=$(gh_codeowners 2>/dev/null | head -10 || true)
            if [[ -n "$owners" ]]; then
                intelligence_section="${intelligence_section}
## Code Owners
${owners}"
            fi
        fi

        # Active security alerts
        if type gh_security_alerts >/dev/null 2>&1; then
            local alerts
            alerts=$(gh_security_alerts 2>/dev/null | head -5 || true)
            if [[ -n "$alerts" ]]; then
                intelligence_section="${intelligence_section}
## Active Security Alerts
${alerts}"
            fi
        fi
    fi

    if $_needs_full_context; then
        # Architecture rules (from intelligence layer)
        local repo_hash
        repo_hash=$(echo -n "$(pwd)" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local arch_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
        if [[ -f "$arch_file" ]]; then
            local arch_rules
            arch_rules=$(jq -r '.rules[]? // empty' "$arch_file" 2>/dev/null | head -10 || true)
            if [[ -n "$arch_rules" ]]; then
                intelligence_section="${intelligence_section}
## Architecture Rules
${arch_rules}"
            fi
        fi

        # Coverage baseline
        local coverage_file="${HOME}/.shipwright/baselines/${repo_hash}/coverage.json"
        if [[ -f "$coverage_file" ]]; then
            local coverage_pct
            coverage_pct=$(jq -r '.coverage_percent // empty' "$coverage_file" 2>/dev/null || true)
            if [[ -n "$coverage_pct" ]]; then
                intelligence_section="${intelligence_section}
## Coverage Baseline
Current coverage: ${coverage_pct}% — do not decrease this."
            fi
        fi
    fi

    # Error classification from last failure — always inject (per-iteration signal)
    local error_log=".claude/pipeline-artifacts/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_error
        last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        if [[ -n "$last_error" ]]; then
            intelligence_section="${intelligence_section}
## Last Error Context
${last_error}"
        fi
    fi

    # Stuckness detection — compare last 3 iteration outputs
    local stuckness_section=""
    stuckness_section="$(detect_stuckness)"
    local _stuck_ret=$?
    local stuckness_detected=false
    [[ "$_stuck_ret" -eq 0 ]] && stuckness_detected=true

    # Propagate stuckness verdict to caller (run_claude_iteration/run_single_agent_loop)
    # so loop can be halted immediately when stuckness is detected on THIS iteration
    export STUCKNESS_DETECTED_THIS_ITERATION="$stuckness_detected"

    # Strategy exploration when stuck — inject as a dedicated section, NOT appended to GOAL.
    # Appending to GOAL mixes "implement these tasks" with "try a different approach" in the
    # same section, creating contradictory directives. Keep them separate.
    local alt_strategy_section=""
    if [[ "$stuckness_detected" == "true" ]]; then
        local last_error diagnosis
        last_error=$(tail -1 "${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/error-log.jsonl" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        [[ -z "$last_error" || "$last_error" == "null" ]] && last_error="unknown"
        diagnosis="${STUCKNESS_DIAGNOSIS:-}"
        local alt_strategy
        alt_strategy=$(explore_alternative_strategy "$last_error" "${ITERATION:-0}" "$diagnosis")
        [[ -n "$alt_strategy" ]] && alt_strategy_section="$alt_strategy"

        # Handle model escalation
        if [[ "${ESCALATE_MODEL:-}" == "true" ]]; then
            if [[ -f "$SCRIPT_DIR/sw-model-router.sh" ]]; then
                source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
            fi
            if type escalate_model &>/dev/null; then
                MODEL=$(escalate_model "${MODEL:-sonnet}")
                info "Escalated to model: $MODEL"
            fi
            unset ESCALATE_MODEL
        fi
    fi

    # Always use ORIGINAL_GOAL so memory-injected prefixes (KNOWN FIX, BLOCKING ISSUES, etc.)
    # never inflate the ## Your Goal section. When stuck, truncate to the first paragraph only.
    local prompt_goal="${ORIGINAL_GOAL:-$GOAL}"
    if [[ "$stuckness_detected" == "true" ]]; then
        prompt_goal="$(printf '%s\n' "$prompt_goal" | awk 'NR==1{print; next} /^[[:space:]]*$/{exit} {print}')"
        [[ -z "$prompt_goal" ]] && prompt_goal="${ORIGINAL_GOAL:-$GOAL}"
    fi

    # Iteration guidance: failure diagnosis, memory KNOWN FIX, and human feedback
    # These are exported by sw-loop.sh but NOT in GOAL (compose_prompt uses ORIGINAL_GOAL),
    # so they must be delivered here rather than being silently dropped.
    local iteration_guidance_section=""
    local _ig_parts=""
    if [[ -n "${LOOP_CLOSED_LOOP_FIX:-}" ]]; then
        _ig_parts="${_ig_parts}KNOWN FIX (from past success): ${LOOP_CLOSED_LOOP_FIX}

"
    fi
    if [[ -n "${LOOP_FAILURE_DIAGNOSIS:-}" ]]; then
        _ig_parts="${_ig_parts}${LOOP_FAILURE_DIAGNOSIS}

"
    fi
    if [[ -n "${LOOP_HUMAN_FEEDBACK:-}" ]]; then
        _ig_parts="${_ig_parts}HUMAN FEEDBACK: ${LOOP_HUMAN_FEEDBACK}

"
    fi
    if [[ -n "$_ig_parts" ]]; then
        iteration_guidance_section="## Iteration Guidance
${_ig_parts}"
    fi

    # Pipeline context section (Layer A: sidecar delivery of synthesized context)
    local pipeline_context_section=""
    if $_needs_full_context; then
        if [[ -n "${LOOP_CONTEXT_FILE:-}" && -f "${LOOP_CONTEXT_FILE:-}" ]]; then
            local _ctx=""
            if [[ -r "${LOOP_CONTEXT_FILE}" ]]; then
                _ctx="$(cat "$LOOP_CONTEXT_FILE" 2>/dev/null || true)"
            else
                warn "context-file '${LOOP_CONTEXT_FILE}' exists but is not readable — proceeding without pipeline context"
            fi
            if [[ -n "$_ctx" ]]; then
                pipeline_context_section="## Pipeline Context
${_ctx}

"
            fi
        fi
    fi

    # Definition of Done — inject when DOD_FILE is set and the file exists
    local dod_section=""
    if [[ -n "${DOD_FILE:-}" && -f "$DOD_FILE" ]]; then
        local _dod_raw
        _dod_raw="$(sed 's/^\([[:space:]]*\)- \[.\] /\1- /' "$DOD_FILE" 2>/dev/null || true)"
        if [[ -n "$_dod_raw" ]]; then
            dod_section="## Definition of Done
${_dod_raw}

The DoD is evaluated automatically against the cumulative branch diff at the end of each iteration.
"
        fi
    fi

    # Session restart context — inject previous session progress
    local restart_section=""
    if [[ "$SESSION_RESTART" == "true" ]] && [[ -f "$LOG_DIR/progress.md" ]]; then
        restart_section="## Previous Session Progress
$(cat "$LOG_DIR/progress.md")

You are starting a FRESH session after the previous one exhausted its iterations.
Read the progress above and continue from where it left off. Do NOT repeat work already done."
    fi

    # Resume-from-checkpoint context — reconstruct Claude context for meaningful resume
    local resume_section=""
    if [[ -n "${RESUMED_FROM_ITERATION:-}" && "${RESUMED_FROM_ITERATION:-0}" -gt 0 ]]; then
        local _test_tail="  (none recorded)"
        [[ -n "${RESUMED_TEST_OUTPUT:-}" ]] && _test_tail="$(echo "$RESUMED_TEST_OUTPUT" | tail -20)"
        resume_section="## RESUMING FROM ITERATION ${RESUMED_FROM_ITERATION}

Continue from where you left off. Do NOT repeat work already done.

Previous work modified these files:
${RESUMED_MODIFIED:-  (none recorded)}

Previous findings/errors from earlier iterations:
${RESUMED_FINDINGS:-  (none recorded)}

Last test output (fix any failures, tail):
${_test_tail}

---
"
        # Clear after first use so we don't keep injecting on every iteration
        RESUMED_FROM_ITERATION=""
        RESUMED_MODIFIED=""
        RESUMED_FINDINGS=""
        RESUMED_TEST_OUTPUT=""
    fi

    # Build cumulative progress summary showing all commits on the WIP branch since creation.
    # Uses _git_branch_merge_base() to find where this branch diverged from the default branch,
    # covering ALL CI jobs on this branch (not just the current session's LOOP_START_COMMIT).
    # Excludes bookkeeping/runtime files so the stat reflects only meaningful code changes.
    # Falls back to LOOP_START_COMMIT if merge-base is unavailable (local-only repo, no remote).
    local cumulative_section=""
    if [[ "${ITERATION:-1}" -gt 1 ]]; then
        local _merge_base
        _merge_base="$(_git_branch_merge_base "" "${LOOP_START_COMMIT:-}" 2>/dev/null || echo "${LOOP_START_COMMIT:-}")"
        if [[ -n "$_merge_base" ]]; then
            local cum_stat
            cum_stat="$(git -C "$PROJECT_ROOT" diff --stat "${_merge_base}..HEAD" -- . $(_git_excluded_pathspecs 2>/dev/null) 2>/dev/null | head -40 || true)"
            if [[ -n "$cum_stat" ]]; then
                cumulative_section="## Cumulative Progress (all branch changes)
${cum_stat}

"
            fi
        fi
    fi

    # Dynamic task progress — auto-marks completed tasks based on cumulative diff
    local task_section=""
    task_section="$(compose_task_section 2>/dev/null || true)"

    local reference_trailer=""
    if ! $_needs_full_context; then
        local _adir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
        reference_trailer="
## Reference (read on demand if needed)
- Plan: \`${_adir}/plan.md\`
- Design: \`${_adir}/design.md\`
- Full build context: \`${_adir}/build-context.md\`"
    fi

    # v2 prompt template — gated behind SHIPWRIGHT_PROMPT_V2=1
    if [[ "${SHIPWRIGHT_PROMPT_V2:-0}" == "1" ]]; then
        # Source the template module if not already loaded
        local _tpl_dir
        _tpl_dir="$(dirname "${BASH_SOURCE[0]}")"
        if [[ -f "${_tpl_dir}/loop-prompt-template.sh" ]] && ! declare -f render_task_header >/dev/null 2>&1; then
            # shellcheck source=./loop-prompt-template.sh
            source "${_tpl_dir}/loop-prompt-template.sh" 2>/dev/null || true
        fi
        if declare -f render_task_header >/dev/null 2>&1; then
            local _v2_adir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
            local _v2_prompt
            _v2_prompt=$(
                render_task_header "${prompt_goal:-${GOAL:-}}" "$(scope_label 2>/dev/null || echo 'Build')" "${MAX_ITERATIONS:-10}"
                render_dynamic_state \
                    "${test_section:-No previous test results}" \
                    "${git_log:-No recent commits}" \
                    "${gate_findings_section:-}" \
                    "${dod_section:-}"
                if declare -f render_design_findings >/dev/null 2>&1; then
                    render_design_findings "${_v2_adir}"
                fi
                render_static_reference "${_v2_adir}"
            )
            echo "$_v2_prompt"
            return 0
        fi
    fi

    # Bash 3.2 compat: heredoc inside $() is rejected by bash 3.2.
    # Write to a temp file, measure with wc -c, cat and remove.
    local _ptmp
    _ptmp=$(mktemp "${TMPDIR:-/tmp}/sw-prompt.XXXXXX")
    cat > "$_ptmp" <<PROMPT
You are an autonomous coding agent. $(scope_label 2>/dev/null || echo "Build Iteration ${ITERATION:-?}") of ${MAX_ITERATIONS} max iterations.
${resume_section}
## Your Goal
${prompt_goal}

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Run tests if a test command exists: ${TEST_CMD:-"(none)"}
5. Commit your work with a descriptive message
6. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

${error_summary_section:+$error_summary_section
}${gate_findings_section:+$gate_findings_section
}${holistic_feedback_section:+$holistic_feedback_section
}${quality_gate_detail_section:+$quality_gate_detail_section
}${rejection_notice_section:+$rejection_notice_section
}${audit_feedback_section:+$audit_feedback_section
}${zero_progress_notice:+$zero_progress_notice
}${stuckness_section:+$stuckness_section
}${alt_strategy_section:+$alt_strategy_section
}${iteration_guidance_section:+$iteration_guidance_section
}${pipeline_context_section}${dod_section}${cumulative_section}${task_section:+## Task Progress
$task_section

}## Current Progress
${recent_log}

## Recent Git Activity
${git_log}

${recent_commits_section}## Test Results (Previous Iteration)
${test_section}

${memory_section:+## Memory Context
$memory_section
}${discovery_section:+## Cross-Pipeline Learnings
$discovery_section
}${dora_section:+$dora_section
}${intelligence_section:+$intelligence_section
}${restart_section:+$restart_section
}${audit_section}

## Context Efficiency
- Batch independent tool calls in parallel — avoid sequential round-trips
- Use targeted file reads (offset/limit) instead of reading entire large files
- Delegate large searches to subagents — only import the summary
- Filter tool results with grep/jq before reasoning over them
- Keep working memory lean — summarize completed steps, don't preserve full outputs

## Rules
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
${reference_trailer}
PROMPT

    local _prompt_chars
    _prompt_chars=$(wc -c < "$_ptmp" | tr -d ' ' 2>/dev/null || echo 0)

    emit_event "context.iteration_prompt" \
        "iteration=${ITERATION:-1}" \
        "chars=${_prompt_chars}" \
        "full_context=${_needs_full_context}" \
        "skipped_pipeline=$( [[ -z "$pipeline_context_section" ]] && echo true || echo false )" \
        "skipped_intelligence_static=$( [[ "$_needs_full_context" == false ]] && echo true || echo false )" \
        2>/dev/null || true

    # Redact out-of-scope file path tokens from the assembled prompt before it reaches the agent.
    # Seam (f): final assembly gate — broadest protection as it catches content from all upstream
    # sources (error-summary, audit_feedback, intelligence_section, gate_findings, commits).
    local _loop_scope_allowlist=""
    _loop_scope_allowlist=$(_extract_scope_from_design 2>/dev/null || true)
    if [ -n "$_loop_scope_allowlist" ]; then
        local _prompt_content
        _prompt_content=$(cat "$_ptmp")
        _prompt_content=$(_redact_paths_outside_scope "$_prompt_content" "$_loop_scope_allowlist" \
            "compose_prompt" "${COMPOUND_QUALITY_CYCLE:-0}" 2>/dev/null \
            || cat "$_ptmp")
        printf '%s' "$_prompt_content" > "$_ptmp"
    fi

    cat "$_ptmp"
    rm -f "$_ptmp"
}

# ─── Alternative Strategy Exploration ─────────────────────────────────────────

explore_alternative_strategy() {
    local last_error="${1:-unknown}"
    local iteration="${2:-0}"
    local diagnosis="${3:-}"

    # Track attempted strategies to avoid repeating them
    local strategy_file="${LOG_DIR:-/tmp}/strategy-attempts.txt"
    local attempted
    attempted=$(cat "$strategy_file" 2>/dev/null || true)

    local strategy=""

    # If quality gates are passing but evaluators disagree, suggest focusing on evaluator alignment
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "${QUALITY_GATE_PASSED:-}" == "true" || "${AUDIT_RESULT:-}" == "pass" ]]; then
        if ! echo "$attempted" | grep -q "evaluator_alignment"; then
            echo "evaluator_alignment" >> "$strategy_file"
            strategy="## Alternative Strategy: Evaluator Alignment
The code appears functionally complete (tests pass). Focus on satisfying the remaining
quality gate evaluators. Check the DoD log and audit log for specific complaints, then
address those exact points rather than adding new features."
        fi
    fi

    # If no code changes in last iteration, suggest verifying existing work
    if echo "$last_error" | grep -qi "no code changes" || [[ "$diagnosis" == *"no code"* ]]; then
        if ! echo "$attempted" | grep -q "verify_existing"; then
            echo "verify_existing" >> "$strategy_file"
            strategy="## Alternative Strategy: Verify Existing Work
Recent iterations made no code changes. The work may already be complete.
Run the full test suite, verify all features work, and if everything passes,
commit a verification message and declare LOOP_COMPLETE with evidence."
        fi
    fi

    # Generic fallback: break the problem down
    if [[ -z "$strategy" ]]; then
        if ! echo "$attempted" | grep -q "decompose"; then
            echo "decompose" >> "$strategy_file"
            strategy="## Alternative Strategy: Decompose
Break the remaining work into smaller, independent steps. Focus on one specific
file or function at a time. Read error messages literally — the root cause may
differ from your assumption."
        fi
    fi

    echo "$strategy"
}

# ─── Claude Execution ────────────────────────────────────────────────────────

build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")
    flags+=("--output-format" "json")
    flags+=("--disallowed-tools" "EnterPlanMode,ExitPlanMode")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    echo "${flags[*]}"
}

run_claude_iteration() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local json_file="$LOG_DIR/iteration-${ITERATION}.json"
    local prompt
    prompt="$(compose_prompt)"
    local final_prompt
    final_prompt=$(manage_context_window "$prompt")

    local raw_prompt_chars=${#prompt}
    local prompt_chars=${#final_prompt}
    local approx_tokens=$((prompt_chars / 4))
    info "Prompt: ~${approx_tokens} tokens (${prompt_chars} chars)"

    # Audit: save full prompt to disk for traceability
    if type audit_save_prompt >/dev/null 2>&1; then
        audit_save_prompt "$final_prompt" "$ITERATION" || true
    fi
    if type audit_emit >/dev/null 2>&1; then
        audit_emit "loop.prompt" "iteration=$ITERATION" "chars=$prompt_chars" \
            "raw_chars=$raw_prompt_chars" "path=iteration-${ITERATION}.prompt.txt" || true
    fi

    # Surface the prompt path; optionally mirror to stdout or GitHub (SW_LOG_PROMPTS).
    local prompt_path="$LOG_DIR/iteration-${ITERATION}.prompt.txt"
    info "Prompt saved → $prompt_path (${prompt_chars} chars)"

    case "${SW_LOG_PROMPTS:-off}" in
        stdout|both)
            echo ""
            echo "━━━━━━━━━━━ BUILD PROMPT — Iteration ${ITERATION} ━━━━━━━━━━━"
            printf '%s\n' "$final_prompt"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            ;;
    esac

    case "${SW_LOG_PROMPTS:-off}" in
        github|both)
            if [[ -n "${ISSUE_NUMBER:-}" ]] && type sanitize_secrets >/dev/null 2>&1; then
                local redacted truncated body
                redacted="$(sanitize_secrets "$final_prompt")"
                if [[ ${#redacted} -gt 50000 ]]; then
                    truncated="${redacted:0:50000} …[TRUNCATED — full prompt at $prompt_path on builder]"
                else
                    truncated="$redacted"
                fi
                local _scope_label
                if type scope_label >/dev/null 2>&1; then
                    _scope_label="$(scope_label 2>/dev/null || echo "Build Iteration ${ITERATION:-?}")"
                else
                    _scope_label="Build Iteration ${ITERATION:-?}"
                fi
                body="### Build Prompt — ${_scope_label}

<details><summary>Prompt (${prompt_chars} chars, redacted)</summary>

\`\`\`
${truncated}
\`\`\`

</details>"
                if [[ -n "${ISSUE_NUMBER:-}" ]] && type gh_comment_issue >/dev/null 2>&1; then
                    gh_comment_issue "$ISSUE_NUMBER" "$body"
                elif type gh_post_progress >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    gh_post_progress "$ISSUE_NUMBER" "$body"
                fi
            fi
            ;;
    esac

    # Emit context efficiency metrics
    if type emit_event >/dev/null 2>&1; then
        local trim_ratio=0
        local budget_utilization=0
        if [[ "$raw_prompt_chars" -gt 0 ]]; then
            trim_ratio=$(awk -v raw="$raw_prompt_chars" -v trimmed="$prompt_chars" \
                'BEGIN { printf "%.1f", ((raw - trimmed) / raw) * 100 }')
        fi
        if [[ "${CONTEXT_BUDGET_CHARS:-0}" -gt 0 ]]; then
            budget_utilization=$(awk -v used="$prompt_chars" -v budget="${CONTEXT_BUDGET_CHARS}" \
                'BEGIN { printf "%.1f", (used / budget) * 100 }')
        fi
        emit_event "loop.context_efficiency" \
            "iteration=$ITERATION" \
            "raw_prompt_chars=$raw_prompt_chars" \
            "trimmed_prompt_chars=$prompt_chars" \
            "trim_ratio=$trim_ratio" \
            "budget_utilization=$budget_utilization" \
            "budget_chars=${CONTEXT_BUDGET_CHARS:-0}" \
            "job_id=${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true
    fi

    local flags
    flags="$(build_claude_flags)"

    local iter_start
    iter_start="$(now_epoch)"

    echo -e "\n${CYAN}${BOLD}▸${RESET} ${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET} — Starting..."

    # Run Claude headless (with timeout + PID capture for signal handling)
    # Output goes to .json first, then we extract text into .log for compat
    local exit_code=0
    # shellcheck disable=SC2086
    local err_file="${json_file%.json}.stderr"
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    else
        claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    fi
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || exit_code=$?
    CHILD_PID=""
    if [[ "$exit_code" -eq 124 ]]; then
        warn "Claude CLI timed out after ${CLAUDE_TIMEOUT}s"
    fi

    # Extract text result from JSON into .log for backwards compatibility
    # With --output-format json, stdout is a JSON array; .[-1].result has the text
    _extract_text_from_json "$json_file" "$log_file" "$err_file"

    local iter_end
    iter_end="$(now_epoch)"
    local iter_duration=$(( iter_end - iter_start ))

    echo -e "  ${GREEN}✓${RESET} Claude session completed ($(format_duration "$iter_duration"), exit $exit_code)"

    # Accumulate token usage from this iteration's JSON output
    accumulate_loop_tokens "$json_file"

    # Emit per-iteration context usage telemetry
    if type emit_event >/dev/null 2>&1 && type get_context_usage_pct >/dev/null 2>&1; then
        local _ctx_pct
        _ctx_pct="$(get_context_usage_pct 2>/dev/null || echo 0)"
        emit_event "loop.context_usage" \
            "iteration=${ITERATION:-0}" \
            "input_tokens=${LOOP_INPUT_TOKENS:-0}" \
            "output_tokens=${LOOP_OUTPUT_TOKENS:-0}" \
            "usage_pct=$_ctx_pct" \
            "threshold=${CONTEXT_EXHAUSTION_THRESHOLD:-70}" || true
    fi

    # Audit: record response metadata
    if type audit_emit >/dev/null 2>&1; then
        local response_chars=0
        [[ -f "$log_file" ]] && response_chars=$(wc -c < "$log_file" | tr -d ' ')
        audit_emit "loop.response" "iteration=$ITERATION" "chars=$response_chars" \
            "exit_code=$exit_code" "duration_s=$iter_duration" \
            "path=iteration-${ITERATION}.json" || true
    fi

    # Show verbose output if requested
    if $VERBOSE; then
        echo -e "  ${DIM}─── Claude Output ───${RESET}"
        sed 's/^/  /' "$log_file" | head -100
        echo -e "  ${DIM}─────────────────────${RESET}"
    fi

    return $exit_code
}

# ─── Iteration Summary Extraction ────────────────────────────────────────────

extract_summary() {
    local log_file="$1"
    [[ ! -s "$log_file" ]] && { echo "(no output)"; return; }

    local summary
    # Prefer an explicit summary block written by the agent (## Summary or ## Iteration Summary).
    summary="$(awk '
        /^## +(Iteration )?[Ss]ummary/ { capture=1; next }
        capture && /^## / { capture=0 }
        capture { print }
    ' "$log_file" | grep -v '^$' | head -20 || true)"

    # Fall back to the last 20 non-blank lines of output.
    if [[ -z "$summary" ]]; then
        summary="$(grep -v '^$' "$log_file" | tail -20 || true)"
    fi

    # Sanitize: if summary is just a CLI/API error, replace with generic text.
    # Warn on session/usage limits so the operator sees the signal before it disappears.
    if echo "$summary" | grep -qiE 'Usage limit reached|out of credits|credit balance|session.*limit|usage.*limit|human turn limit|claude\.ai/usage'; then
        warn "Session/usage limit detected in iteration output — loop will abort on fatal error check"
        summary="(CLI error — no useful output this iteration)"
    elif echo "$summary" | grep -qiE 'Invalid API key|authentication_error|rate_limit|API key expired|ANTHROPIC_API_KEY'; then
        summary="(CLI error — no useful output this iteration)"
    fi

    # LOOP_COMPLETE / <<<LOOP:PASS>>> markers are intentionally preserved so the
    # next iteration's compose_iteration_outcome can pair them with rejection detail.
    # No per-line char truncation — manage_context_window handles prompt size.
    echo "$summary"
}

# compose_iteration_outcome — renders a structured outcome block for the just-finished
# iteration. Called after run_quality_gates so all gate globals are populated.
# Output is appended to the iteration log entry read by the next iteration's prompt.
compose_iteration_outcome() {
    local outcome=""
    if $COMPLETION_REJECTED; then
        outcome="**Outcome: LOOP_COMPLETE was REJECTED.**
Reason(s): ${QUALITY_GATE_REASONS:-quality gates failed}"
        if [[ -n "${QUALITY_GATE_DETAIL:-}" ]]; then
            outcome="${outcome}

Specific failures:
${QUALITY_GATE_DETAIL}"
        fi
    elif [[ "${QUALITY_GATE_PASSED:-true}" == "false" ]]; then
        outcome="**Outcome: gates FAILED** — ${QUALITY_GATE_REASONS:-see above}"
        if [[ -n "${QUALITY_GATE_DETAIL:-}" ]]; then
            outcome="${outcome}

${QUALITY_GATE_DETAIL}"
        fi
    elif [[ "${TEST_PASSED:-true}" == "false" ]]; then
        outcome="**Outcome: tests FAILED** in this iteration."
    else
        outcome="**Outcome: iteration completed; gates pending or passed.**"
    fi
    printf '%s' "$outcome"
}
