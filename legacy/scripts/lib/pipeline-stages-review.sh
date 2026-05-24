# pipeline-stages-review.sh — review, compound_quality, audit stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_REVIEW_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_REVIEW_LOADED=1

# detect_plan_drift — compare plan.md "## Files to Modify" against git diff
# Inputs:  $1=artifacts_dir  $2=project_root
# Output:  newline-separated [DRIFT-WARNING] lines, or empty string
# Behavior: fail-open — returns empty string if plan.md missing, parse fails, or git fails
detect_plan_drift() {
    local artifacts_dir="${1:-}"
    local project_root="${2:-.}"
    local plan_file="${artifacts_dir}/plan.md"

    # Fail-open: empty artifacts_dir or no plan.md → no warnings
    [[ -n "$artifacts_dir" ]] || return 0
    [[ -s "$plan_file" ]] || return 0

    # Extract the "## Files to Modify" section (case-insensitive heading match).
    # Accepts h2 (##) or h3 (###) headings with optional trailing colon.
    # Stops at the next h2 OR at known sibling h3 sections that follow in Shipwright plans
    # (Implementation Steps, Task Checklist, Testing Approach, Definition of Done).
    # Does NOT stop at deeper h3 subheadings within the section (e.g. ### Core Files).
    local section
    section=$(awk '
        tolower($0) ~ /^###? files to modify[[:space:]]*:?[[:space:]]*$/ { found=1; next }
        found && /^## / { exit }
        found && /^### / {
            h = tolower($0)
            sub(/^###[[:space:]]+/, "", h)
            gsub(/[[:space:]]*:[[:space:]]*$/, "", h)
            gsub(/[[:space:]]+/, " ", h)
            if (h ~ /^(implementation steps|task checklist|testing approach|definition of done)$/) exit
        }
        found { print }
    ' "$plan_file" 2>/dev/null) || return 0

    # Fail-open: section not found → no warnings
    [[ -n "$section" ]] || return 0

    # Get actual changed files; fail-open if git fails entirely.
    # Validate base branch — check local ref first, then origin/<base>.
    local actual_changed=""
    local _git_ok=true
    local _base="${BASE_BRANCH:-main}"
    if ! (cd "$project_root" && { git rev-parse --verify "$_base" >/dev/null 2>&1 || git rev-parse --verify "origin/$_base" >/dev/null 2>&1; }); then
        return 0
    fi
    if declare -f _safe_base_diff >/dev/null 2>&1; then
        actual_changed=$( (cd "$project_root" && _safe_base_diff --name-only) 2>/dev/null) || _git_ok=false
    else
        actual_changed=$(cd "$project_root" && git diff --name-only "${_base}..HEAD" 2>/dev/null) || _git_ok=false
    fi
    [[ "$_git_ok" == "true" ]] || return 0

    local drift_warnings=""

    # Parse bullet list items from the section
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Only process bullet items (lines starting with optional whitespace + "- ")
        echo "$line" | grep -q '^[[:space:]]*- ' || continue

        local planned_file=""
        local _from_backtick=false
        # Prefer backtick-quoted path: `path/to/file.sh`
        if echo "$line" | grep -q '`[^`]*`'; then
            planned_file=$(echo "$line" | sed "s/^[^\`]*\`\([^\`]*\)\`.*/\1/")
            _from_backtick=true
        else
            # Fall back to first token after "- "
            planned_file=$(echo "$line" | sed 's/^[[:space:]]*- //' | awk '{print $1}')
        fi

        [[ -z "$planned_file" ]] && continue
        # Strip leading "./" — git diff --name-only never emits it, but authors may write it
        planned_file="${planned_file#./}"
        # For plain-text tokens (non-backtick), require . or / to filter common English words.
        # Backtick-quoted tokens are trusted as file paths (covers Makefile, Dockerfile, etc.)
        if [[ "$_from_backtick" != "true" ]]; then
            echo "$planned_file" | grep -qE '(\.|/)' || continue
        fi

        # Check if this planned file appears in the actual changed files (whole-line match,
        # case-insensitive to handle macOS/Windows where git may normalize path casing)
        if ! echo "$actual_changed" | grep -qixF "$planned_file"; then
            drift_warnings="${drift_warnings}[DRIFT-WARNING] Planned file not modified: ${planned_file}
"
        fi
    done <<< "$section"

    printf '%s' "$drift_warnings"
}

stage_review() {
    CURRENT_STAGE_ID="review"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-review.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _review_retry_hints
        _review_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    local diff_file="$ARTIFACTS_DIR/review-diff.patch"
    local review_file="$ARTIFACTS_DIR/review.md"

    _safe_base_diff > "$diff_file" 2>/dev/null || true

    if [[ ! -s "$diff_file" ]]; then
        warn "No diff found — skipping review"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        warn "Claude CLI not found — skipping AI review"
        return 0
    fi

    local diff_stats
    diff_stats=$(_safe_base_diff --stat | tail -1 || echo "")
    info "Running AI code review... ${DIM}($diff_stats)${RESET}"

    # Semantic risk scoring when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        local diff_files
        diff_files=$(_safe_base_diff --name-only || true)
        local risk_score="low"
        # Fast heuristic: flag high-risk file patterns
        if echo "$diff_files" | grep -qiE 'migration|schema|auth|crypto|security|password|token|secret|\.env'; then
            risk_score="high"
        elif echo "$diff_files" | grep -qiE 'api|route|controller|middleware|hook'; then
            risk_score="medium"
        fi
        emit_event "review.risk_assessed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "risk=$risk_score" \
            "files_changed=$(_trim "$(echo "$diff_files" | wc -l)")"
        if [[ "$risk_score" == "high" ]]; then
            warn "High-risk changes detected (DB schema, auth, crypto, or secrets)"
        fi
    fi

    # T2.4: Scope audit — compute off-scope files deterministically in shell before
    # prompting Claude, so the reviewer cannot miss a scope violation.
    local _scope_violations_block=""
    local _scope_violations_file="${ARTIFACTS_DIR}/issue-${ISSUE_NUMBER:-0}/logs/scope-violations.txt"
    if declare -f _extract_scope_from_design >/dev/null 2>&1 && \
       declare -f _compute_scope_violations >/dev/null 2>&1; then
        local _review_scope _review_changed _review_violations
        _review_scope=$(_extract_scope_from_design "$ARTIFACTS_DIR" 2>/dev/null)
        if [[ -n "$_review_scope" ]]; then
            _review_changed=$(_safe_base_diff --name-only 2>/dev/null || true)
            if [[ -n "$_review_changed" ]]; then
                _review_violations=$(_compute_scope_violations "$_review_changed" "$_review_scope" 2>/dev/null)
                if [[ -n "$_review_violations" ]]; then
                    mkdir -p "$(dirname "$_scope_violations_file")" 2>/dev/null || true
                    printf '%s\n' "$_review_violations" > "$_scope_violations_file" 2>/dev/null || true
                    local _viol_list
                    _viol_list=$(printf '%s\n' "$_review_violations" | sed 's/^/  - /')
                    _scope_violations_block="
SCOPE AUDIT (computed deterministically from git diff vs design.md):
The following files are out of declared scope:
${_viol_list}
For each file above, you MUST emit a finding in this exact format (so the review parser counts it as blocking):
  **[Critical]** SCOPE VIOLATION: <path> is out of declared scope per design.md — revert this file or update the design.
Then explain (one paragraph) what the change appears to do and whether the design should be updated to include it.
"
                    emit_event "review.scope_violations" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "count=$(printf '%s\n' "$_review_violations" | wc -l | tr -d ' ')" 2>/dev/null || true
                fi
            fi
        fi
    fi

    local review_model="${MODEL:-opus}"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        review_model="$CLAUDE_MODEL"
    fi

    # Ruflo parallel review hive — run before native review to inject hive findings
    # as additional context into the review prompt. Fail-open: if the hive fails,
    # native single-agent review continues unaffected.
    local _hive_review_file="$ARTIFACTS_DIR/review-hive-context.md"
    local _hive_review_context=""
    if declare -f ruflo_execute_review >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _diff_content
        _diff_content=$(cat "$diff_file" 2>/dev/null || true)
        if [[ -n "$_diff_content" ]] && ruflo_execute_review "$_diff_content" "$_hive_review_file"; then
            info "Ruflo parallel review hive complete — augmenting native review"
            if [[ -s "$_hive_review_file" ]]; then
                _hive_review_context=$(head -c 3000 "$_hive_review_file" 2>/dev/null || true)
            fi
        else
            warn "Ruflo parallel review failed — falling back to native single-agent review"
            emit_event "ruflo.review_fallback" "reason=hive_failed" || true
        fi
    fi

    # Build review prompt with project context
    local review_prompt="You are a senior code reviewer. Review this git diff thoroughly.

For each issue found, use this format:
- **[SEVERITY]** file:line — description

Severity levels: Critical, Bug, Security, Warning, Suggestion

Focus on:
1. Logic bugs and edge cases
2. Security vulnerabilities (injection, XSS, auth bypass, etc.)
3. Error handling gaps
4. Performance issues
5. Missing validation
6. Project convention violations (see conventions below)

Be specific. Reference exact file paths and line numbers. Only flag genuine issues.
If no issues are found, write: \"Review clean — no issues found.\"
"

    # Inject scope violations block when out-of-scope files were detected (T2.4)
    if [[ -n "$_scope_violations_block" ]]; then
        review_prompt+="${_scope_violations_block}"
    fi

    # Inject previous review findings and anti-patterns from memory
    if type intelligence_search_memory >/dev/null 2>&1; then
        local review_memory
        review_memory=$(intelligence_search_memory "code review findings anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        review_memory=$(prune_context_section "memory" "$review_memory" 10000)
        if [[ -n "$review_memory" ]]; then
            review_prompt+="
## Known Issues from Previous Reviews
These anti-patterns and issues have been found in past reviews of this codebase. Flag them if they recur:
${review_memory}
"
        fi
    fi

    # Inject project conventions if CLAUDE.md exists
    local claudemd="$PROJECT_ROOT/.claude/CLAUDE.md"
    if [[ -f "$claudemd" ]]; then
        local conventions
        conventions=$(grep -A2 'Common Pitfalls\|Shell Standards\|Bash 3.2' "$claudemd" 2>/dev/null | head -20 || true)
        if [[ -n "$conventions" ]]; then
            review_prompt+="
## Project Conventions
${conventions}
"
        fi
    fi

    # Inject CODEOWNERS focus areas for review
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_codeowners >/dev/null 2>&1; then
        local review_owners
        review_owners=$(gh_codeowners 2>/dev/null | head -10 || true)
        if [[ -n "$review_owners" ]]; then
            review_prompt+="
## Code Owners (focus areas)
${review_owners}
"
        fi
    fi

    # Inject Definition of Done if present
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"
    if [[ -f "$dod_file" ]]; then
        review_prompt+="
## Definition of Done (verify these)
$(cat "$dod_file")
"
    fi

    # Inject skill prompts for review stage
    # Prefer adaptive selection when available
    if type skill_select_adaptive >/dev/null 2>&1; then
        local _review_skill_files _review_skills
        _review_skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_review_skill_files" ]]; then
            _review_skills=$(while IFS= read -r _path; do
                [[ -z "$_path" ]] && continue
                [[ -f "$_path" ]] && cat "$_path" 2>/dev/null
            done <<< "$_review_skill_files")
            if [[ -n "$_review_skills" ]]; then
                _review_skills=$(prune_context_section "review-skills" "$_review_skills" 5000)
                review_prompt+="
## Review Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_review_skills}
"
            fi
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        # Fallback to static selection
        local _review_skills
        _review_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" 2>/dev/null || true)
        if [[ -n "$_review_skills" ]]; then
            _review_skills=$(prune_context_section "review-skills" "$_review_skills" 5000)
            review_prompt+="
## Review Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue)
${_review_skills}
"
        fi
    fi

    # Inject test evidence to prevent false "missing code" criticals on pre-existing identifiers
    local test_log="$ARTIFACTS_DIR/test-results.log"
    if [[ -f "$test_log" ]]; then
        local test_summary test_status_line
        test_summary=$(tail -5 "$test_log" 2>/dev/null || echo "")
        # Determine pass/fail from log content — sidecar-first, then grep fallback
        local _review_ec=""
        _review_ec=$(pipeline_test_status 2>/dev/null || true)
        if [[ "$_review_ec" == "0" ]]; then
            test_status_line="The full test suite was run by the pipeline BEFORE this review and PASSED (exit 0, from test-results.status.json)."
        elif [[ -n "$_review_ec" ]]; then
            test_status_line="The full test suite was run by the pipeline BEFORE this review and FAILED (exit ${_review_ec}, from test-results.status.json)."
        else
            if grep -qiE '(tests? passed|0 failures|0 failed|all.*passed|\bpassed\b)' "$test_log" 2>/dev/null \
               && ! grep -qiE '(tests? failed|[1-9][0-9]* failure|[1-9][0-9]* failed|\bFAIL\b)' "$test_log" 2>/dev/null; then
                test_status_line="The full test suite was run by the pipeline BEFORE this review and PASSED (exit 0)."
            else
                test_status_line="The test suite was run by the pipeline BEFORE this review (see last output lines below)."
            fi
        fi
        review_prompt+="
## Test Evidence (Pipeline Verified — Trust This)
${test_status_line}

CRITICAL REVIEWER INSTRUCTION: If a test references an identifier, method, or property
that does not appear in this diff, it is already present in the codebase from prior commits.
Do NOT flag 'missing code' or 'will cause test failure' issues for anything the passing
tests have already verified. The diff shows only CHANGES — not the complete codebase.

Last test output lines:
${test_summary}
"
    fi

    # Detect plan-to-build drift: warn when planned files were not touched by the build
    local _drift_warnings=""
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        _drift_warnings=$(detect_plan_drift "$ARTIFACTS_DIR" "${PROJECT_ROOT:-.}" 2>/dev/null || true)
    fi
    if [[ -n "$_drift_warnings" ]]; then
        review_prompt+="
## Cross-Stage Drift Detected
The following files were planned but not modified by the build:
${_drift_warnings}
Reviewer: Verify whether these files were intentionally skipped or represent incomplete implementation.
"
        emit_event "review.drift_detected" "issue=${ISSUE_NUMBER:-0}" || true
    fi

    # Seam (e): redact out-of-scope paths from diff content before injecting into review prompt.
    local _rev_diff_content
    _rev_diff_content=$(cat "$diff_file" 2>/dev/null || true)
    if declare -f _redact_paths_outside_scope >/dev/null 2>&1 && \
       declare -f _extract_scope_from_design >/dev/null 2>&1; then
        local _rev_scope_allowlist=""
        _rev_scope_allowlist=$(_extract_scope_from_design "$ARTIFACTS_DIR" 2>/dev/null || true)
        if [ -n "$_rev_scope_allowlist" ]; then
            _rev_diff_content=$(_redact_paths_outside_scope "$_rev_diff_content" \
                "$_rev_scope_allowlist" "review_diff" "${COMPOUND_QUALITY_CYCLE:-0}" \
                2>/dev/null || cat "$diff_file")
        fi
    fi

    review_prompt+="
## Diff to Review
${_rev_diff_content}"

    # Inject skill prompts for review stage
    _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "review" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "review" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        review_prompt="${review_prompt}
## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    # Inject prior stage context from ruflo (supplements file-based artifacts)
    if declare -f ruflo_available >/dev/null 2>&1 && \
       declare -f ruflo_recall >/dev/null 2>&1 && \
       ruflo_available; then
        local _prior_context
        _prior_context=$(ruflo_recall "plan design build results for ${TASK_TYPE:-feature}" \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" 2>/dev/null || true)
        if [[ -n "$_prior_context" ]]; then
            review_prompt="${review_prompt}

## Prior Stage Context (from ruflo memory)
${_prior_context}"
        fi
        review_prompt="${review_prompt}

## Ruflo Memory Available
Ruflo MCP tools are available in this session. Use mcp__ruflo__memory_store to persist
important decisions and mcp__ruflo__memory_search to recall prior context from namespace
'pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}'."
    fi

    # Inject parallel hive reviewer findings — union of all specialist reviewer outputs
    # (security, code_quality, test_gap, architecture). Only present when ruflo hive
    # completed successfully above.
    if [[ -n "$_hive_review_context" ]]; then
        review_prompt="${review_prompt}

## Parallel Hive Reviewer Findings (ruflo — union aggregation)
${_hive_review_context}"
    fi

    # Guard total prompt size
    review_prompt=$(guard_prompt_size "review" "$review_prompt")

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Same rationale as build stage (line ~1083).
    local review_args=(--print --model "$review_model" --max-turns 25 --dangerously-skip-permissions)

    # ── Two-Stage Review: Pass 1 (Spec Compliance) ──
    local _two_stage=false
    if type skill_has_two_stage_review >/dev/null 2>&1 && skill_has_two_stage_review "${INTELLIGENCE_ISSUE_TYPE:-backend}"; then
        _two_stage=true
        local spec_review_file="$ARTIFACTS_DIR/review-spec.md"
        local plan_file="$ARTIFACTS_DIR/plan.md"

        if [[ -s "$plan_file" ]]; then
            info "Two-stage review: Pass 1 — Spec compliance"
            local spec_prompt="You are a spec compliance reviewer. Compare the implementation against the plan.

## Plan
$(cat "$plan_file" 2>/dev/null | head -200)

## Implementation Diff
$(cat "$diff_file" 2>/dev/null)

## Task
Compare the diff against the plan:
1. Does the code implement every task from the plan's checklist?
2. Were all planned files actually modified?
3. Is anything from the plan NOT implemented?
4. Was anything added that WASN'T in the plan?

For each gap found:
- **[SPEC-GAP]** description — what was planned vs what was implemented

If all requirements are met, write: \"Spec compliance: PASS — all planned tasks implemented.\"
"
            # Inject prior stage context from ruflo into spec compliance prompt
            if declare -f ruflo_available >/dev/null 2>&1 && \
               declare -f ruflo_recall >/dev/null 2>&1 && \
               ruflo_available; then
                local _spec_prior_context
                _spec_prior_context=$(ruflo_recall "plan design build results for ${TASK_TYPE:-feature}" \
                    "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" 2>/dev/null || true)
                if [[ -n "$_spec_prior_context" ]]; then
                    spec_prompt="${spec_prompt}

## Prior Stage Context (from ruflo memory)
${_spec_prior_context}"
                fi
                spec_prompt="${spec_prompt}

## Ruflo Memory Available
Ruflo MCP tools are available in this session. Use mcp__ruflo__memory_store to persist
important decisions and mcp__ruflo__memory_search to recall prior context from namespace
'pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}'."
            fi
            spec_prompt=$(guard_prompt_size "spec-review" "$spec_prompt")
            claude "${review_args[@]}" "$spec_prompt" < /dev/null > "$spec_review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-spec-review.log" || true
            parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-spec-review.log"

            if [[ -s "$spec_review_file" ]]; then
                local spec_gaps
                spec_gaps=$(grep -c 'SPEC-GAP' "$spec_review_file" 2>/dev/null || true)
                spec_gaps="${spec_gaps:-0}"
                if [[ "$spec_gaps" -gt 0 ]]; then
                    warn "Spec review found $spec_gaps gap(s) — see $spec_review_file"
                else
                    success "Spec compliance: PASS"
                fi
                emit_event "review.spec_complete" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "gaps=$spec_gaps"
            fi
            info "Two-stage review: Pass 2 — Code quality"
        fi
    fi

    claude "${review_args[@]}" "$review_prompt" < /dev/null > "$review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-review.log" || true
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-review.log"

    if [[ ! -s "$review_file" ]]; then
        warn "Review produced no output — check ${ARTIFACTS_DIR}/.claude-tokens-review.log for errors"
        return 0
    fi

    # Extract severity counts — try JSON structure first, then grep fallback
    local critical_count=0 bug_count=0 warning_count=0

    # Check if review output is structured JSON (e.g. from structured review tools)
    local json_parsed=false
    if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
        local j_critical j_bug j_warning
        j_critical=$(jq -r '.issues | map(select(.severity == "Critical")) | length' "$review_file" 2>/dev/null || echo "")
        if [[ -n "$j_critical" && "$j_critical" != "null" ]]; then
            critical_count="$j_critical"
            bug_count=$(jq -r '.issues | map(select(.severity == "Bug" or .severity == "Security")) | length' "$review_file" 2>/dev/null || echo "0")
            warning_count=$(jq -r '.issues | map(select(.severity == "Warning" or .severity == "Suggestion")) | length' "$review_file" 2>/dev/null || echo "0")
            json_parsed=true
        fi
    fi

    # Grep fallback for markdown-formatted review output
    if [[ "$json_parsed" != "true" ]]; then
        critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$review_file" 2>/dev/null || true)
        critical_count="${critical_count:-0}"
        bug_count=$(grep -ciE '\*\*\[?(Bug|Security)\]?\*\*' "$review_file" 2>/dev/null || true)
        bug_count="${bug_count:-0}"
        warning_count=$(grep -ciE '\*\*\[?(Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
        warning_count="${warning_count:-0}"
    fi
    local total_issues=$((critical_count + bug_count + warning_count))

    # M7: Fail-closed scope count — shell computed N violations; review must contain ≥ N scope findings.
    # Prevents Claude from silently omitting scope findings when the prompt told it to emit them.
    if [[ -f "$_scope_violations_file" ]] && [[ -s "$_scope_violations_file" ]]; then
        local _shell_scope_count _parsed_scope_count
        _shell_scope_count=$(wc -l < "$_scope_violations_file" 2>/dev/null | tr -d ' ' || echo 0)
        _parsed_scope_count=$(grep -ciE 'SCOPE VIOLATION' "$review_file" 2>/dev/null || echo 0)
        if (( _shell_scope_count > 0 && _parsed_scope_count < _shell_scope_count )); then
            error "Review fail-closed: ${_shell_scope_count} shell-computed scope violation(s) but only ${_parsed_scope_count} scope finding(s) in review output — review omitted a required finding."
            return 1
        fi
    fi

    if [[ "$critical_count" -gt 0 ]]; then
        error "Review found ${BOLD}$critical_count critical${RESET} issue(s) — see $review_file"
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Review found $bug_count bug/security issue(s) — see ${DIM}$review_file${RESET}"
    elif [[ "$total_issues" -gt 0 ]]; then
        info "Review found $total_issues suggestion(s)"
    else
        success "Review clean"
    fi

    # ── Oversight gate: pipeline review/quality stages block on verdict ──
    # Compute blocking issues and save blockers early (for self-healing, independent of gates)
    # Exclude [Pre-existing] lines from counts — they are not introduced by this PR.
    local _sec_count _blocking reject_reason=""
    _sec_count=$(grep -iE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null \
        | grep -civE '\[Pre-existing\]' || true)
    _sec_count="${_sec_count:-0}"
    _blocking=$((critical_count + _sec_count))
    [[ "$_blocking" -gt 0 ]] && reject_reason="Review found ${_blocking} critical/security issue(s)"
    if [[ "$_blocking" -gt 0 ]]; then
        grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$review_file" \
            | grep -viE '\[Pre-existing\]' \
            > "$ARTIFACTS_DIR/review-blockers.md" 2>/dev/null || true
    fi
    # Partition pre-existing findings to a follow-up file (not blockers).
    grep -iE '\[Pre-existing\]' "$review_file" \
        > "$ARTIFACTS_DIR/review-followups.md" 2>/dev/null || true
    if [[ -x "$SCRIPT_DIR/sw-oversight.sh" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        if ! bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$diff_file" --description "${GOAL:-Pipeline review}" --reject-if "$reject_reason" >/dev/null 2>&1; then
            error "Oversight gate rejected — blocking pipeline"
            emit_event "review.oversight_blocked" "issue=${ISSUE_NUMBER:-0}"
            log_stage "review" "BLOCKED: oversight gate rejected"
            return 1
        fi
    fi

    # ── Review Blocking Gate ──
    # Block pipeline on critical/security issues unless compound_quality handles them
    # Exclude [Pre-existing] lines from blocking counts — only PR-introduced findings block.
    local security_count
    security_count=$(grep -iE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null \
        | grep -civE '\[Pre-existing\]' || true)
    security_count="${security_count:-0}"

    local blocking_issues=$((critical_count + security_count))

    if [[ "$blocking_issues" -gt 0 ]]; then
        # Check if compound_quality stage is enabled — if so, let it handle issues
        local compound_enabled="false"
        if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
            compound_enabled=$(jq -r '.stages[] | select(.id == "compound_quality") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null) || true
            [[ -z "$compound_enabled" || "$compound_enabled" == "null" ]] && compound_enabled="false"
        fi

        # Check if this is a fast template (don't block fast pipelines)
        local is_fast="false"
        if [[ "${PIPELINE_NAME:-}" == "fast" || "${PIPELINE_NAME:-}" == "hotfix" ]]; then
            is_fast="true"
        fi

        if [[ "$compound_enabled" == "true" ]]; then
            info "Review found ${blocking_issues} critical/security issue(s) — compound_quality stage will handle"
        elif [[ "$is_fast" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — fast template, not blocking"
        elif [[ "${SKIP_GATES:-false}" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — skip-gates mode, not blocking"
        else
            error "Review found ${BOLD}${blocking_issues} critical/security issue(s)${RESET} — blocking pipeline"
            emit_event "review.blocked" \
                "issue=${ISSUE_NUMBER:-0}" \
                "critical=${critical_count}" \
                "security=${security_count}"

            # Save blocking issues for self-healing context (exclude pre-existing findings)
            grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$review_file" \
                | grep -viE '\[Pre-existing\]' \
                > "$ARTIFACTS_DIR/review-blockers.md" 2>/dev/null || true

            # Post review to GitHub before failing
            if [[ -n "$ISSUE_NUMBER" ]]; then
                local review_summary
                review_summary=$(head -40 "$review_file")
                gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review — ❌ Blocked

**Stats:** $diff_stats
**Blocking issues:** ${blocking_issues} (${critical_count} critical, ${security_count} security)

<details>
<summary>Review details</summary>

${review_summary}

</details>

_Pipeline will attempt self-healing rebuild._"
            fi

            log_stage "review" "BLOCKED: $blocking_issues critical/security issues found"
            return 1
        fi
    fi

    # Post review to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local review_summary
        review_summary=$(head -40 "$review_file")
        gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review

**Stats:** $diff_stats
**Issues found:** $total_issues (${critical_count} critical, ${bug_count} bugs, ${warning_count} suggestions)

<details>
<summary>Review details</summary>

${review_summary}

</details>"
    fi

    # Store review summary in ruflo for cross-stage context
    if declare -f ruflo_store >/dev/null 2>&1 && [[ -s "$review_file" ]]; then
        ruflo_store "stage-review-result" \
            "$(head -c 4000 "$review_file" 2>/dev/null || true)" \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
    fi

    # Store review outcome in issue namespace
    if type ruflo_store_issue_outcome >/dev/null 2>&1; then
        local _review_ts
        _review_ts="$(date +%s 2>/dev/null || echo 0)"
        local _verdict
        if [[ "$blocking_issues" -gt 0 ]]; then
            _verdict="blocked"
        elif [[ "$critical_count" -gt 0 ]]; then
            _verdict="critical"
        elif [[ "$bug_count" -gt 0 ]]; then
            _verdict="bugs"
        else
            _verdict="clean"
        fi
        ruflo_store_issue_outcome \
            "review-${SHIPWRIGHT_PIPELINE_ID:-$$}-${_review_ts}" \
            "$(jq -n --arg goal "${GOAL:-}" --arg verdict "$_verdict" \
                '{goal:$goal,stage:"review",verdict:$verdict}' 2>/dev/null || echo '{}')" \
            "review,${TASK_TYPE:-feature}" 2>/dev/null || true
    fi

    log_stage "review" "AI review complete ($total_issues issues: $critical_count critical, $bug_count bugs, $warning_count suggestions)"
}

# ─── Compound Quality (fallback) ────────────────────────────────────────────
# Basic implementation: adversarial review, negative testing, e2e checks, DoD audit.
# If pipeline-intelligence.sh was sourced first, its enhanced version takes priority.
if ! type stage_compound_quality >/dev/null 2>&1; then
stage_compound_quality() {
    CURRENT_STAGE_ID="compound_quality"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-compound_quality.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _cq_retry_hints
        _cq_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi

    # Load skill prompts for compound quality (used by adversarial review)
    local _cq_skills=""
    if type skill_load_prompts >/dev/null 2>&1; then
        _cq_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "compound_quality" 2>/dev/null || true)
    fi
    # Write skill guidance to artifact for sw-adversarial.sh to consume
    if [[ -n "$_cq_skills" ]]; then
        echo "$_cq_skills" > "${ARTIFACTS_DIR}/.compound-quality-skills.md" 2>/dev/null || true
    fi
    if [[ -n "${_cq_retry_hints:-}" ]]; then
        echo "$_cq_retry_hints" >> "${ARTIFACTS_DIR}/.compound-quality-skills.md" 2>/dev/null || true
    fi

    # Ruflo adversarial quality hive — run early to collect parallel findings.
    # Writes to a separate file; findings are appended to compound_log AFTER
    # compound_log is declared and initialized below (avoids unbound-variable
    # error under set -u and prevents `: > "$compound_log"` from wiping findings).
    local _hive_cq_file="$ARTIFACTS_DIR/cq-hive-context.md"
    local _hive_cq_ok=false
    if declare -f ruflo_execute_compound_quality >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _cq_diff_content
        _cq_diff_content=$(cat "$ARTIFACTS_DIR/review-diff.patch" 2>/dev/null || true)
        if [[ -n "$_cq_diff_content" ]] && \
           ruflo_execute_compound_quality "$_cq_diff_content" "$_hive_cq_file"; then
            info "Ruflo adversarial quality hive complete"
            _hive_cq_ok=true
        else
            warn "Ruflo compound quality hive failed — continuing with native checks"
            emit_event "ruflo.cq_fallback" "reason=hive_failed" || true
        fi
    fi

    # Read stage config from pipeline template
    local cfg
    cfg=$(jq -r '.stages[] | select(.id == "compound_quality") | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null) || cfg="{}"

    local do_adversarial do_negative do_e2e do_dod max_cycles blocking
    do_adversarial=$(echo "$cfg" | jq -r '.adversarial // false')
    do_negative=$(echo "$cfg" | jq -r '.negative // false')
    do_e2e=$(echo "$cfg" | jq -r '.e2e // false')
    do_dod=$(echo "$cfg" | jq -r '.dod_audit // false')
    max_cycles=$(echo "$cfg" | jq -r '.max_cycles // 1')
    blocking=$(echo "$cfg" | jq -r '.compound_quality_blocking // false')

    # High/critical risk issues get stricter compound quality — force adversarial + negative
    local _risk="${SHIPWRIGHT_RISK_LEVEL:-unknown}"
    if [[ "$_risk" == "high" || "$_risk" == "critical" ]]; then
        do_adversarial="true"
        do_negative="true"
        info "Risk level is $_risk — enabling adversarial and negative testing"
    fi

    local pass_count=0 fail_count=0 total=0
    local compound_log="$ARTIFACTS_DIR/compound-quality.log"
    : > "$compound_log"

    # Append ruflo hive findings now that compound_log is declared and initialized
    if [[ "$_hive_cq_ok" == "true" && -s "$_hive_cq_file" ]]; then
        cat "$_hive_cq_file" >> "$compound_log" 2>/dev/null || true
    fi

    # ── Adversarial review ──
    if [[ "$do_adversarial" == "true" ]]; then
        total=$((total + 1))
        info "Running adversarial review..."
        if [[ -x "$SCRIPT_DIR/sw-adversarial.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-adversarial.sh" --repo "${REPO_DIR:-.}" >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "Adversarial review passed"
            else
                fail_count=$((fail_count + 1))
                warn "Adversarial review found issues"
            fi
        else
            warn "sw-adversarial.sh not found, skipping"
        fi
    fi

    # ── Negative / edge-case testing ──
    if [[ "$do_negative" == "true" ]]; then
        total=$((total + 1))
        info "Running negative test pass..."
        if [[ -n "${TEST_CMD:-}" ]]; then
            if eval "$TEST_CMD" >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "Negative test pass passed"
            else
                fail_count=$((fail_count + 1))
                warn "Negative test pass found failures"
            fi
        else
            pass_count=$((pass_count + 1))
            info "No test command configured, skipping negative tests"
        fi
    fi

    # ── E2E checks ──
    if [[ "$do_e2e" == "true" ]]; then
        total=$((total + 1))
        info "Running e2e checks..."
        if [[ -x "$SCRIPT_DIR/sw-e2e-orchestrator.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-e2e-orchestrator.sh" run >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "E2E checks passed"
            else
                fail_count=$((fail_count + 1))
                warn "E2E checks found issues"
            fi
        else
            pass_count=$((pass_count + 1))
            info "sw-e2e-orchestrator.sh not found, skipping e2e"
        fi
    fi

    # ── Definition of Done audit ──
    if [[ "$do_dod" == "true" ]]; then
        total=$((total + 1))
        info "Running definition-of-done audit..."
        if [[ -x "$SCRIPT_DIR/sw-quality.sh" ]]; then
            if bash "$SCRIPT_DIR/sw-quality.sh" validate >> "$compound_log" 2>&1; then
                pass_count=$((pass_count + 1))
                success "DoD audit passed"
            else
                fail_count=$((fail_count + 1))
                warn "DoD audit found gaps"
            fi
        else
            pass_count=$((pass_count + 1))
            info "sw-quality.sh not found, skipping DoD audit"
        fi
    fi

    # ── Summary ──
    log_stage "compound_quality" "Compound quality: $pass_count/$total checks passed, $fail_count failed"

    if [[ "$fail_count" -gt 0 && "$blocking" == "true" ]]; then
        error "Compound quality gate failed: $fail_count of $total checks failed"
        return 1
    fi

    return 0
}
fi  # end fallback stage_compound_quality

# ─── Audit Stage ───────────────────────────────────────────────────────────
# Security and quality audits: secrets scan, file permissions, || true usage,
# test coverage delta, atomic write checks.
stage_audit() {
    CURRENT_STAGE_ID="audit"

    # Read stage config from pipeline template
    local cfg
    cfg=$(jq -r '.stages[] | select(.id == "audit") | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null) || cfg="{}"

    local do_secret_scan do_perms do_atomic_writes do_coverage blocking
    do_secret_scan=$(echo "$cfg" | jq -r '.secret_scan // true')
    do_perms=$(echo "$cfg" | jq -r '.file_permissions // true')
    do_atomic_writes=$(echo "$cfg" | jq -r '.atomic_writes // true')
    do_coverage=$(echo "$cfg" | jq -r '.coverage_delta // true')
    blocking=$(echo "$cfg" | jq -r '.blocking // false')

    local audit_log="$ARTIFACTS_DIR/audit.log"
    : > "$audit_log"

    local issues=0

    # Ruflo parallel security audit hive — run before native checks to collect
    # specialist findings (CVE, secrets, OWASP, compliance) in parallel.
    # Fail-open: if the hive fails, native sequential checks continue unaffected.
    local _hive_audit_file="$ARTIFACTS_DIR/audit-hive-context.md"
    local _hive_audit_ok=false
    if declare -f ruflo_execute_audit >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _audit_diff_content
        _audit_diff_content=$(cat "$ARTIFACTS_DIR/review-diff.patch" 2>/dev/null || true)
        if [[ -n "$_audit_diff_content" ]] && \
           ruflo_execute_audit "$_audit_diff_content" "$_hive_audit_file"; then
            info "Ruflo parallel security audit hive complete"
            _hive_audit_ok=true
        else
            warn "Ruflo security audit hive failed — continuing with native checks"
            emit_event "ruflo.audit_fallback" "reason=hive_failed" || true
        fi
    fi

    # Append ruflo hive audit findings before native checks run
    if [[ "$_hive_audit_ok" == "true" && -s "$_hive_audit_file" ]]; then
        cat "$_hive_audit_file" >> "$audit_log" 2>/dev/null || true
    fi

    # ── Secret Scanning ──
    if [[ "$do_secret_scan" == "true" ]]; then
        info "Scanning for secrets in changed files..."
        local secret_patterns=(
            "sk-ant-" "ANTHROPIC_API_KEY=" "GITHUB_TOKEN=" "OPENAI_API_KEY="
            "AWS_SECRET_ACCESS_KEY=" "DATABASE_URL=" "PRIVATE_KEY="
            "api_key=" "secret=" "password=" "token="
        )

        local changed_files
        changed_files=$(git diff --name-only "${BASE_BRANCH:-main}..HEAD" 2>/dev/null || git diff --name-only HEAD~5 2>/dev/null || echo "")

        for pattern in "${secret_patterns[@]}"; do
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if grep -l "$pattern" "$file" 2>/dev/null | grep -qv node_modules; then
                    echo "WARN: Potential secret found in $file: $pattern" >> "$audit_log"
                    warn "Found potential secret: $pattern in $file"
                    issues=$((issues + 1))
                fi
            done <<< "$changed_files"
        done
    fi

    # ── File Permission Check ──
    if [[ "$do_perms" == "true" ]]; then
        info "Checking file permissions on sensitive files..."
        local sensitive_patterns=(".env" "secret" "credential" "key" "token" "config")

        for pattern in "${sensitive_patterns[@]}"; do
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                # Check for world-readable files
                local perms
                perms=$(stat -f "%OLp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null)
                if [[ "$perms" =~ [4567]$ ]]; then  # world-readable
                    echo "WARN: World-readable sensitive file: $file ($perms)" >> "$audit_log"
                    warn "World-readable file: $file ($perms)"
                    issues=$((issues + 1))
                fi
            done < <(find . -name "*${pattern}*" -type f 2>/dev/null | head -20)
        done
    fi

    # ── || true Count (atomic write pattern) ──
    if [[ "$do_atomic_writes" == "true" ]]; then
        info "Checking for unprotected direct writes (|| true usage)..."
        local baseline_true_count=0
        local current_true_count=0

        # Baseline (before changes)
        if git rev-parse "${BASE_BRANCH:-main}" >/dev/null 2>&1; then
            baseline_true_count=$(git show "${BASE_BRANCH:-main}:." 2>/dev/null | grep -r "|| true" 2>/dev/null | wc -l)
        fi

        # Current
        current_true_count=$(grep -r "|| true" --include="*.sh" . 2>/dev/null | wc -l)

        local true_delta=$((current_true_count - baseline_true_count))
        if [[ $true_delta -gt 0 ]]; then
            echo "WARN: Added $true_delta new '|| true' clauses (may mask errors)" >> "$audit_log"
            warn "Added $true_delta new || true patterns"
            issues=$((issues + 1))
        fi
    fi

    # ── Test Coverage Delta ──
    if [[ "$do_coverage" == "true" && -n "${COVERAGE_FILE:-}" ]]; then
        info "Comparing test coverage..."
        if [[ -f "$COVERAGE_FILE" ]]; then
            local current_coverage
            current_coverage=$(grep -oP 'Coverage: \K[0-9.]+' "$COVERAGE_FILE" | head -1)
            if [[ -n "$current_coverage" ]]; then
                # Try to get baseline coverage
                local baseline_coverage=0
                if git show "${BASE_BRANCH:-main}:.claude/coverage.txt" >/dev/null 2>&1; then
                    baseline_coverage=$(git show "${BASE_BRANCH:-main}:.claude/coverage.txt" 2>/dev/null | \
                        grep -oP 'Coverage: \K[0-9.]+' | head -1 || echo "0")
                fi

                local coverage_delta
                coverage_delta=$(echo "$current_coverage - $baseline_coverage" | bc 2>/dev/null || echo "0")
                if (( $(echo "$coverage_delta < -2" | bc -l 2>/dev/null || echo 0) )); then
                    echo "WARN: Coverage decreased by ${coverage_delta}pp (from ${baseline_coverage}% to ${current_coverage}%)" >> "$audit_log"
                    warn "Coverage delta: ${coverage_delta}pp"
                    issues=$((issues + 1))
                fi
            fi
        fi
    fi

    log_stage "audit" "Audit complete: $issues issue(s) found"

    if [[ "$issues" -gt 0 && "$blocking" == "true" ]]; then
        error "Audit gate failed: $issues issue(s) detected"
        emit_event "pipeline.audit_failed" "issues=$issues"
        return 1
    fi

    if [[ "$issues" -gt 0 ]]; then
        emit_event "pipeline.audit_warnings" "issues=$issues"
    fi

    return 0
}

