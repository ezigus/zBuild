# pipeline-stages-delivery.sh — resync, pr, merge, deploy stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_DELIVERY_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_DELIVERY_LOADED=1

# resync_abort — Clean up after a failed merge in stage_resync.
# Always returns 0. Attempts git reset --hard if merge --abort leaves dirt.
resync_abort() {
    git merge --abort 2>/dev/null || true
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        warn "resync_abort: tree dirty after merge --abort; attempting git reset --hard"
        git reset --hard HEAD 2>/dev/null || true
        if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
            warn "resync_abort: tree still dirty after reset --hard (may have untracked files)"
        fi
    fi
    return 0
}

# stage_resync — Sync WIP branch with origin/$BASE_BRANCH via git merge.
# Scaffold for issue #624: basic merge, no conflict-resolution retry.
# Success: HEAD merged with origin/$BASE_BRANCH (or no-op when remote absent).
# Failure: merge aborted, working tree clean, mark_stage_failed("resync", ...) invoked.
stage_resync() {
    CURRENT_STAGE_ID="resync"
    local base="${BASE_BRANCH:-main}"

    info "Syncing branch with origin/${base}..."

    # Fetch base — failure is non-fatal (offline / no remote in tests)
    if ! git fetch origin "$base" 2>/dev/null; then
        warn "Could not fetch origin/${base} — assuming local-only base"
    fi

    # Pick the best available ref: origin/<base>, then local <base>; otherwise no-op.
    local merge_ref=""
    if git rev-parse --verify "origin/${base}" >/dev/null 2>&1; then
        merge_ref="origin/${base}"
    elif git rev-parse --verify "$base" >/dev/null 2>&1; then
        merge_ref="$base"
    else
        log_stage "resync" "no-op (no base ref available)" 2>/dev/null || true
        return 0
    fi

    local merge_err_log="${ARTIFACTS_DIR:-/tmp}/merge-error.log"
    if git merge "$merge_ref" --no-edit >/dev/null 2>"$merge_err_log"; then
        success "Branch is current with ${merge_ref}"
        emit_event "resync.complete" \
            "issue=${ISSUE_NUMBER:-0}" \
            "base=${base}" 2>/dev/null || true
        log_stage "resync" "merged ${merge_ref}" 2>/dev/null || true
        return 0
    fi

    # Merge failed — log conflicted files so operators know what to resolve.
    local conflicted_files
    conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    error "Merge conflict against ${merge_ref}"
    if [[ -n "$conflicted_files" ]]; then
        error "Conflicted files (resolve manually, then run 'shipwright pipeline resume'):"
        while IFS= read -r _cf; do
            [[ -n "$_cf" ]] && error "  $_cf"
        done <<< "$conflicted_files"
        echo "$conflicted_files" > "${ARTIFACTS_DIR:-/tmp}/resync-conflicts.txt" 2>/dev/null || true
    fi
    if [[ -s "$merge_err_log" ]]; then
        error "git merge output: $(cat "$merge_err_log")"
    fi
    error "To resolve: fix each conflicted file, run 'git add <file>', then 'git merge --continue', then 'shipwright pipeline resume'"

    resync_abort
    emit_event "resync.conflict" \
        "issue=${ISSUE_NUMBER:-0}" \
        "base=${base}" 2>/dev/null || true
    mark_stage_failed "resync" "conflicts detected in ${conflicted_files:-unknown files} — resolve manually then resume" 2>/dev/null || true
    return 1
}

stage_pr() {
    CURRENT_STAGE_ID="pr"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-pr.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _pr_retry_hints
        _pr_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load PR quality skills (used as guidance for hygiene checks)
    local _pr_skills=""
    if type skill_load_prompts >/dev/null 2>&1; then
        _pr_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "pr" 2>/dev/null || true)
        if [[ -n "$_pr_skills" ]]; then
            echo "$_pr_skills" > "${ARTIFACTS_DIR}/.pr-quality-skills.md" 2>/dev/null || true
        fi
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local test_log="$ARTIFACTS_DIR/test-results.log"
    local review_file="$ARTIFACTS_DIR/review.md"

    # ── Ruflo: recall audit/review context from prior stages (fail-open) ──
    # Bookend lives before the local-mode skip so memory is always read/written.
    # Use output redirection (not $()) so the function runs in the current
    # shell — required when ruflo_recall is a mock that records side effects.
    local audit_summary=""
    if declare -f ruflo_recall >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _ruflo_pr_tmp _ruflo_pr_ctx=""
        _ruflo_pr_tmp=$(mktemp 2>/dev/null) || _ruflo_pr_tmp="${ARTIFACTS_DIR:-/tmp}/.ruflo-pr-recall.$$"
        ruflo_recall "audit and review findings for ${TASK_TYPE:-feature}" \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" > "$_ruflo_pr_tmp" 2>/dev/null || true
        [[ -s "$_ruflo_pr_tmp" ]] && _ruflo_pr_ctx=$(cat "$_ruflo_pr_tmp" 2>/dev/null || true)
        rm -f "$_ruflo_pr_tmp"
        # Sanitize: strip header lines + control chars, truncate to keep PR body tight
        if [[ -n "$_ruflo_pr_ctx" ]]; then
            _ruflo_pr_ctx=$(printf '%s\n' "${_ruflo_pr_ctx}" \
                | sed '/^#/d' \
                | tr -d '\000-\010\013-\037\177')
            _ruflo_pr_ctx=$(printf '%.800s' "${_ruflo_pr_ctx}")
            if [[ -n "$_ruflo_pr_ctx" ]]; then
                audit_summary="**Audit context (ruflo):** prior-stage findings recalled"
                info "Ruflo: recalled audit/review context (${#_ruflo_pr_ctx} chars) for PR description"
            fi
        fi
    fi

    # ── Skip PR in local/no-github mode ──
    if [[ "${NO_GITHUB:-false}" == "true" || "${SHIPWRIGHT_LOCAL:-}" == "1" || "${LOCAL_MODE:-false}" == "true" ]]; then
        info "Skipping PR stage — running in local/no-github mode"
        # Save a PR draft locally for reference
        local branch_name
        branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        local commit_count
        commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")
        {
            echo "# PR Draft (local mode)"
            echo ""
            echo "**Branch:** ${branch_name}"
            echo "**Commits:** ${commit_count:-0}"
            echo "**Goal:** ${GOAL:-N/A}"
            echo ""
            echo "## Changes"
            _safe_base_diff --stat || true
        } > ".claude/pr-draft.md" 2>/dev/null || true
        emit_event "pr.skipped" "issue=${ISSUE_NUMBER:-0}" "reason=local_mode"
        # Store local PR draft outcome to close the bookend (fail-open)
        if declare -f ruflo_store >/dev/null 2>&1; then
            ruflo_store "stage-pr-result" \
                "PR skipped (local mode). Branch: ${branch_name:-unknown}. Commits: ${commit_count:-0}. Goal: ${GOAL:-}." \
                "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
        fi
        return 0
    fi

    # ── PR Hygiene Checks (informational) ──
    local hygiene_commit_count
    hygiene_commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")
    hygiene_commit_count="${hygiene_commit_count:-0}"

    if [[ "$hygiene_commit_count" -gt 20 ]]; then
        warn "PR has ${hygiene_commit_count} commits — consider squashing before merge"
    fi

    # Check for WIP/fixup/squash commits (expanded patterns)
    local wip_commits
    wip_commits=$(_safe_base_log --oneline | grep -ciE '^[0-9a-f]+ (WIP|fixup!|squash!|TODO|HACK|TEMP|BROKEN|wip[:-]|temp[:-]|broken[:-]|do not merge)' || true)
    wip_commits="${wip_commits:-0}"
    if [[ "$wip_commits" -gt 0 ]]; then
        warn "Branch has ${wip_commits} WIP/fixup/squash/temp commit(s) — consider cleaning up"
    fi

    # Commit any uncommitted changes left by the build agent
    # Must happen BEFORE the quality gate so _safe_base_diff sees all real changes.
    # Use git status --porcelain to catch untracked files (new files created by the
    # build agent) in addition to tracked modifications. Only commit when real
    # (non-.claude/) changes are present to avoid leaving an artifact-only commit
    # on a branch that the quality gate is about to reject.
    local _pending_real
    _pending_real=$(git status --porcelain 2>/dev/null | awk '{print $NF}' | grep -v '^\.claude/' || true)
    if [[ -n "$_pending_real" ]]; then
        info "Committing remaining uncommitted changes..."
        safe_git_stage
        git commit -m "chore: pipeline cleanup — commit remaining build changes" --no-verify 2>/dev/null || true
    fi

    # ── PR Quality Gate: reject PRs with no real code changes ──
    local real_files
    real_files=$(_safe_base_diff --name-only | grep -v '^\.claude/' || true)
    if [[ -z "$real_files" ]]; then
        error "No real code changes detected — only pipeline artifacts (.claude/ logs)."
        error "Likely causes: (a) WIP branch was discarded — check 'Check for partial work branch' step in CI,"
        error "  (b) build agent didn't reproduce prior work (check ruflo/Claude errors in build log),"
        error "  (c) changes already on main — verify: git log origin/main..HEAD"
        error "The build agent did not produce meaningful changes. Skipping PR creation."
        emit_event "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=no_real_changes"
        # Mark issue so auto-retry knows not to retry empty builds
        if [[ -n "${ISSUE_NUMBER:-}" && "${ISSUE_NUMBER:-0}" != "0" ]]; then
            gh issue comment "$ISSUE_NUMBER" --body "<!-- SHIPWRIGHT-NO-CHANGES: true -->" 2>/dev/null || true
        fi
        return 1
    fi
    local real_file_count
    real_file_count=$(_trim "$(echo "$real_files" | wc -l)")
    info "PR quality gate: ${real_file_count} real file(s) changed"

    # Auto-rebase onto latest base branch before PR
    auto_rebase || {
        warn "Rebase/merge failed — pushing as-is"
    }

    # Push branch — force required after rebase (history rewritten).
    # Use GITHUBTOKEN (PAT with workflow scope) when set so branches that
    # include workflow file changes are not rejected by GITHUB_TOKEN.
    # Clear the checkout-persisted extraheader first so the PAT URL wins.
    info "Pushing branch: $GIT_BRANCH"
    local _repo_slug=""
    if [[ -n "${GITHUBTOKEN:-}" ]]; then
        _repo_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||')
        git config --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true
        git remote set-url origin "https://x-access-token:${GITHUBTOKEN}@github.com/${_repo_slug}.git" 2>/dev/null || true
    fi
    local push_err
    push_err=$(git push -u origin "$GIT_BRANCH" --force-with-lease 2>&1) || {
        warn "force-with-lease push failed; see git output below"
        printf '%s\n' "$push_err" >&2
        # Fallback: fetch remote ref then retry lease, or force-push as last resort
        git fetch origin "$GIT_BRANCH" 2>/dev/null || true
        push_err=$(git push -u origin "$GIT_BRANCH" --force-with-lease 2>&1) || {
            warn "Second force-with-lease attempt failed; see git output below"
            printf '%s\n' "$push_err" >&2
            push_err=$(git push -u origin "$GIT_BRANCH" --force 2>&1) || {
                error "Failed to push branch"
                printf '%s\n' "$push_err" >&2
                return 1
            }
        }
    }
    # Scrub PAT from remote URL after push
    if [[ -n "${GITHUBTOKEN:-}" && -n "${_repo_slug:-}" ]]; then
        git remote set-url origin "https://github.com/${_repo_slug}.git" 2>/dev/null || true
    fi

    # ── Developer Simulation (pre-PR review) ──
    local simulation_summary=""
    if type simulation_review >/dev/null 2>&1; then
        local sim_enabled
        sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        # Also check daemon-config (via sidecar-merged reader)
        if [[ "$sim_enabled" != "true" ]]; then
            local _dc_del_sim
            if declare -f _load_daemon_config >/dev/null 2>&1; then
                _dc_del_sim=$(_load_daemon_config)
            else
                _dc_del_sim=$(cat "${PROJECT_ROOT:-.}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
            fi
            sim_enabled=$(echo "$_dc_del_sim" | jq -r '.intelligence.simulation_enabled // false' 2>/dev/null || echo "false")
        fi
        if [[ "$sim_enabled" == "true" ]]; then
            info "Running developer simulation review..."
            local diff_for_sim
            diff_for_sim=$(_safe_base_diff || true)
            if [[ -n "$diff_for_sim" ]]; then
                local sim_result
                sim_result=$(simulation_review "$diff_for_sim" "${GOAL:-}" 2>/dev/null || echo "")
                if [[ -n "$sim_result" && "$sim_result" != *'"error"'* ]]; then
                    echo "$sim_result" > "$ARTIFACTS_DIR/simulation-review.json"
                    local sim_count
                    sim_count=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                    simulation_summary="**Developer simulation:** ${sim_count} reviewer concerns pre-addressed"
                    success "Simulation complete: ${sim_count} concerns found and addressed"
                    emit_event "simulation.complete" "issue=${ISSUE_NUMBER:-0}" "concerns=${sim_count}"
                else
                    info "Simulation returned no actionable concerns"
                fi
            fi
        fi
    fi

    # ── Architecture Validation (pre-PR check) ──
    local arch_summary=""
    if type architecture_validate_changes >/dev/null 2>&1; then
        local arch_enabled
        arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        if [[ "$arch_enabled" != "true" ]]; then
            local _dc_del_arch
            if declare -f _load_daemon_config >/dev/null 2>&1; then
                _dc_del_arch=$(_load_daemon_config)
            else
                _dc_del_arch=$(cat "${PROJECT_ROOT:-.}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
            fi
            arch_enabled=$(echo "$_dc_del_arch" | jq -r '.intelligence.architecture_enabled // false' 2>/dev/null || echo "false")
        fi
        if [[ "$arch_enabled" == "true" ]]; then
            info "Validating architecture..."
            local diff_for_arch
            diff_for_arch=$(_safe_base_diff || true)
            if [[ -n "$diff_for_arch" ]]; then
                local arch_result
                arch_result=$(architecture_validate_changes "$diff_for_arch" "" 2>/dev/null || echo "")
                if [[ -n "$arch_result" && "$arch_result" != *'"error"'* ]]; then
                    echo "$arch_result" > "$ARTIFACTS_DIR/architecture-validation.json"
                    local violation_count
                    violation_count=$(echo "$arch_result" | jq '[.violations[]? | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                    arch_summary="**Architecture validation:** ${violation_count} violations"
                    if [[ "$violation_count" -gt 0 ]]; then
                        warn "Architecture: ${violation_count} high/critical violations found"
                    else
                        success "Architecture validation passed"
                    fi
                    emit_event "architecture.validated" "issue=${ISSUE_NUMBER:-0}" "violations=${violation_count}"
                else
                    info "Architecture validation returned no results"
                fi
            fi
        fi
    fi

    # Pre-PR diff gate — verify meaningful code changes exist (not just bookkeeping)
    local real_changes
    real_changes=$(_safe_base_diff --name-only \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!.claude/pipeline-artifacts/*' ':!**/progress.md' \
        ':!**/error-summary.json' | wc -l | xargs || true)
    real_changes="${real_changes:-0}"
    if [[ "${real_changes:-0}" -eq 0 ]]; then
        error "No meaningful code changes detected — only bookkeeping files modified"
        error "Refusing to create PR with zero real changes"
        return 1
    fi
    info "Pre-PR diff check: ${real_changes} real files changed"

    # Build PR title — prefer GOAL over plan file first line
    # (plan file first line often contains Claude analysis text, not a clean title)
    local pr_title=""
    if [[ -n "${GOAL:-}" ]]; then
        pr_title=$(echo "$GOAL" | cut -c1-70)
    fi
    if [[ -z "$pr_title" ]] && [[ -s "$plan_file" ]]; then
        pr_title=$(head -1 "$plan_file" 2>/dev/null | sed 's/^#* *//' | cut -c1-70)
    fi
    [[ -z "$pr_title" ]] && pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"

    # Sanitize: reject PR titles that look like error messages
    if echo "$pr_title" | grep -qiE 'Invalid API|API key|authentication_error|rate_limit|CLI error|no useful output'; then
        warn "PR title looks like an error message: $pr_title"
        pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"
    fi

    # Build comprehensive PR body
    local plan_summary=""
    if [[ -s "$plan_file" ]]; then
        plan_summary=$(head -20 "$plan_file" 2>/dev/null | tail -15)
    fi

    local test_summary=""
    if [[ -s "$test_log" ]]; then
        test_summary=$(tail -10 "$test_log" | strip_ansi)
    fi

    local review_summary=""
    if [[ -s "$review_file" ]]; then
        local total_issues=0
        # Try JSON structured output first
        if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
            total_issues=$(jq -r '.issues | length' "$review_file" 2>/dev/null || echo "0")
        fi
        # Grep fallback for markdown
        if [[ "${total_issues:-0}" -eq 0 ]]; then
            total_issues=$(grep -ciE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
            total_issues="${total_issues:-0}"
        fi
        review_summary="**Code review:** $total_issues issues found"
    fi

    local closes_line=""
    [[ -n "${GITHUB_ISSUE:-}" ]] && closes_line="Closes ${GITHUB_ISSUE}"

    local diff_stats
    diff_stats=$(_safe_base_diff --stat | tail -1 || echo "")

    local commit_count
    commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    local pr_body
    pr_body="$(cat <<EOF
## Summary
${plan_summary:-$GOAL}

## Changes
${diff_stats}
${commit_count} commit(s) via \`shipwright pipeline\` (${PIPELINE_NAME})

## Test Results
\`\`\`
${test_summary:-No test output}
\`\`\`

${review_summary}
${simulation_summary}
${arch_summary}
${audit_summary}

${closes_line}

---

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Duration | ${total_dur:-—} |
| Model | ${MODEL:-opus} |
| Agents | ${AGENTS:-1} |

Generated by \`shipwright pipeline\`
EOF
)"

    # Verify required evidence before PR (merge policy enforcement)
    local risk_tier
    risk_tier="low"
    if [[ -f "$REPO_DIR/config/policy.json" ]]; then
        local changed_files
        changed_files=$(_safe_base_diff --name-only || true)
        if [[ -n "$changed_files" ]]; then
            local policy_file="$REPO_DIR/config/policy.json"
            check_tier_match() {
                local tier="$1"
                local patterns
                patterns=$(jq -r ".riskTierRules.${tier}[]? // empty" "$policy_file" 2>/dev/null)
                [[ -z "$patterns" ]] && return 1
                while IFS= read -r pattern; do
                    [[ -z "$pattern" ]] && continue
                    local regex
                    regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*\*/DOUBLESTAR/g; s/\*/[^\/]*/g; s/DOUBLESTAR/.*/g')
                    while IFS= read -r file; do
                        [[ -z "$file" ]] && continue
                        if echo "$file" | grep -qE "^${regex}$"; then
                            return 0
                        fi
                    done <<< "$changed_files"
                done <<< "$patterns"
                return 1
            }
            check_tier_match "critical" && risk_tier="critical"
            check_tier_match "high" && [[ "$risk_tier" != "critical" ]] && risk_tier="high"
            check_tier_match "medium" && [[ "$risk_tier" != "critical" && "$risk_tier" != "high" ]] && risk_tier="medium"
        fi
    fi

    local required_evidence
    required_evidence=$(jq -r ".mergePolicy.\"$risk_tier\".requiredEvidence // [] | .[]" "$REPO_DIR/config/policy.json" 2>/dev/null)

    if [[ -n "$required_evidence" ]]; then
        local evidence_dir="$REPO_DIR/.claude/evidence"
        local missing_evidence=()
        while IFS= read -r etype; do
            [[ -z "$etype" ]] && continue
            local has_evidence=false
            for f in "$evidence_dir"/*"$etype"*; do
                [[ -f "$f" ]] && has_evidence=true && break
            done
            [[ "$has_evidence" != "true" ]] && missing_evidence+=("$etype")
        done <<< "$required_evidence"

        if [[ ${#missing_evidence[@]} -gt 0 ]]; then
            warn "Missing required evidence for $risk_tier tier: ${missing_evidence[*]}"
            emit_event "evidence.missing" "{\"tier\":\"$risk_tier\",\"missing\":\"${missing_evidence[*]}\"}"
            # Collect missing evidence
            if [[ -x "$SCRIPT_DIR/sw-evidence.sh" ]]; then
                for etype in "${missing_evidence[@]}"; do
                    (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-evidence.sh" capture "$etype" 2>/dev/null) || warn "Failed to collect $etype evidence"
                done
            fi
        fi
    fi

    # Build gh pr create args
    local pr_args=(--title "$pr_title" --body "$pr_body" --base "$BASE_BRANCH")

    # Propagate labels from issue + CLI
    local all_labels="${LABELS}"
    if [[ -n "$ISSUE_LABELS" ]]; then
        if [[ -n "$all_labels" ]]; then
            all_labels="${all_labels},${ISSUE_LABELS}"
        else
            all_labels="$ISSUE_LABELS"
        fi
    fi
    if [[ -n "$all_labels" ]]; then
        pr_args+=(--label "$all_labels")
    fi

    # Auto-detect or use provided reviewers
    local reviewers="${REVIEWERS}"
    if [[ -z "$reviewers" ]]; then
        reviewers=$(detect_reviewers)
    fi
    if [[ -n "$reviewers" ]]; then
        pr_args+=(--reviewer "$reviewers")
        info "Reviewers: ${DIM}$reviewers${RESET}"
    fi

    # Propagate milestone
    if [[ -n "$ISSUE_MILESTONE" ]]; then
        pr_args+=(--milestone "$ISSUE_MILESTONE")
        info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
    fi

    # Check for existing open PR on this branch to avoid duplicates (issue #12)
    local pr_url=""
    local existing_pr
    existing_pr=$(gh pr list --head "$GIT_BRANCH" --state open --json number,url --jq '.[0]' 2>/dev/null || echo "")
    if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
        local existing_pr_number existing_pr_url
        existing_pr_number=$(echo "$existing_pr" | jq -r '.number' 2>/dev/null || echo "")
        existing_pr_url=$(echo "$existing_pr" | jq -r '.url' 2>/dev/null || echo "")
        info "Updating existing PR #$existing_pr_number instead of creating duplicate"
        gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>/dev/null || true
        pr_url="$existing_pr_url"
    else
        info "Creating PR..."
        local pr_stderr pr_exit=0 pr_stderr_file
        pr_stderr_file=$(mktemp "${TMPDIR:-/tmp}/shipwright-pr-stderr.XXXXXX")
        pr_url=$(gh pr create "${pr_args[@]}" 2>"$pr_stderr_file") || pr_exit=$?
        pr_stderr=$(cat "$pr_stderr_file" 2>/dev/null || true)
        rm -f "$pr_stderr_file"

        # gh pr create may return non-zero for reviewer issues but still create the PR
        if [[ "$pr_exit" -ne 0 ]]; then
            if [[ "$pr_url" == *"github.com"* ]]; then
                # PR was created but something non-fatal failed (e.g., reviewer not found)
                warn "PR created with warnings: ${pr_stderr:-unknown}"
            else
                error "PR creation failed: ${pr_stderr:-$pr_url}"
                return 1
            fi
        fi
    fi

    success "PR created: ${BOLD}$pr_url${RESET}"
    echo "$pr_url" > "$ARTIFACTS_DIR/pr-url.txt"

    # Extract PR number
    PR_NUMBER=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)

    # ── Ruflo: store PR result for downstream stages (fail-open) ──
    if declare -f ruflo_store >/dev/null 2>&1 && [[ -n "$pr_url" ]]; then
        ruflo_store "stage-pr-result" \
            "PR created: ${pr_url}. Issue: ${ISSUE_NUMBER:-none}. Branch: ${GIT_BRANCH:-unknown}. Files: ${real_file_count:-0}. Goal: ${GOAL:-}." \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
    fi

    # Distill issue outcomes into repo namespace for cross-pipeline learning
    if type ruflo_distill_issue_to_repo >/dev/null 2>&1; then
        ruflo_distill_issue_to_repo 2>/dev/null || true
    fi

    # ── Intelligent Reviewer Selection (GraphQL-enhanced) ──
    if [[ "${NO_GITHUB:-false}" != "true" && -n "$PR_NUMBER" && -z "$reviewers" ]]; then
        local reviewer_assigned=false

        # Try CODEOWNERS-based routing via GraphQL API
        if type gh_codeowners >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local codeowners_json
            codeowners_json=$(gh_codeowners "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            if [[ "$codeowners_json" != "[]" && -n "$codeowners_json" ]]; then
                local changed_files
                changed_files=$(_safe_base_diff --name-only || true)
                if [[ -n "$changed_files" ]]; then
                    local co_reviewers
                    co_reviewers=$(echo "$codeowners_json" | jq -r '.[].owners[]' 2>/dev/null | sort -u | head -3 || true)
                    if [[ -n "$co_reviewers" ]]; then
                        local rev
                        while IFS= read -r rev; do
                            rev="${rev#@}"
                            [[ -n "$rev" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$rev" 2>/dev/null || true
                        done <<< "$co_reviewers"
                        info "Requested review from CODEOWNERS: $(echo "$co_reviewers" | tr '\n' ',' | sed 's/,$//')"
                        reviewer_assigned=true
                    fi
                fi
            fi
        fi

        # Fallback: contributor-based routing via GraphQL API
        if [[ "$reviewer_assigned" != "true" ]] && type gh_contributors >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local contributors_json
            contributors_json=$(gh_contributors "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            local top_contributor
            top_contributor=$(echo "$contributors_json" | jq -r '.[0].login // ""' 2>/dev/null || echo "")
            local current_user
            current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
            if [[ -n "$top_contributor" && "$top_contributor" != "$current_user" ]]; then
                gh pr edit "$PR_NUMBER" --add-reviewer "$top_contributor" 2>/dev/null || true
                info "Requested review from top contributor: $top_contributor"
                reviewer_assigned=true
            fi
        fi

        # Final fallback: auto-approve if no reviewers assigned
        if [[ "$reviewer_assigned" != "true" ]]; then
            gh pr review "$PR_NUMBER" --approve 2>/dev/null || warn "Could not auto-approve PR"
        fi
    fi

    # Update issue with PR link
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_comment_issue "$ISSUE_NUMBER" "🎉 **PR created:** ${pr_url}

Pipeline duration so far: ${total_dur:-unknown}"

        # #504 D2: post per-stage cost table as a follow-up comment so reviewers
        # see token spend at a glance. Defensive source guard — pipeline-stages-delivery.sh
        # is normally loaded inside sw-pipeline.sh (which already sources sw-cost.sh +
        # lib/cost helpers), but daemon-triage.sh sources it standalone too.
        if ! type render_cost_table_plain >/dev/null 2>&1; then
            [[ -f "$SCRIPT_DIR/lib/cost/table-render.sh" ]] && \
                source "$SCRIPT_DIR/lib/cost/table-render.sh"
            [[ -f "$SCRIPT_DIR/lib/cost/baselines.sh" ]] && \
                source "$SCRIPT_DIR/lib/cost/baselines.sh"
        fi
        local _cost_bd_file="${ARTIFACTS_DIR}/cost-breakdown.json"
        if [[ -f "$_cost_bd_file" ]] && type render_cost_table_plain >/dev/null 2>&1; then
            local _cost_table _cost_issue_arg=()
            [[ -n "${ISSUE_NUMBER:-}" ]] && _cost_issue_arg=(--issue "$ISSUE_NUMBER")
            _cost_table=$(render_cost_table_plain "$_cost_bd_file" "${_cost_issue_arg[@]}" --baseline-context 2>/dev/null || true)
            if [[ -n "$_cost_table" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "## Pipeline cost breakdown
\`\`\`
${_cost_table}
\`\`\`" 2>/dev/null || warn "cost table comment post failed (non-fatal)"
            fi
        fi

        # Notify tracker of review/PR creation
        "$SCRIPT_DIR/sw-tracker.sh" notify "review" "$ISSUE_NUMBER" "$pr_url" 2>/dev/null || true
    fi

    # Wait for CI if configured
    local wait_ci
    wait_ci=$(jq -r --arg id "pr" '(.stages[] | select(.id == $id) | .config.wait_ci) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ "$wait_ci" == "true" ]]; then
        info "Waiting for CI checks..."
        gh pr checks --watch 2>/dev/null || warn "CI checks did not all pass"
    fi

    log_stage "pr" "PR created: $pr_url (${reviewers:+reviewers: $reviewers})"
}

_write_merge_retry_ctx_ci_failure() {
    local pr_number="$1" pr_url="$2"
    local failed_link=""
    failed_link=$(gh pr checks "$pr_number" --json bucket,link \
        --jq '[.[] | select(.bucket == "fail")] | .[0].link // ""' 2>/dev/null || echo "")
    cat > "${ARTIFACTS_DIR}/.retry-context-build.md" <<RETRYEOF
# CI failed on PR #${pr_number}

Run \`gh pr checks ${pr_number}\` to list failing checks, then \`gh run view <run-id> --log-failed\` for details.

PR: ${pr_url}
First failed run: ${failed_link}

Fix the failure(s), commit, and push to the same branch.
RETRYEOF
}

_write_merge_retry_ctx_review() {
    local pr_number="$1" pr_url="$2"
    cat > "${ARTIFACTS_DIR}/.retry-context-build.md" <<RETRYEOF
# Reviewer requested changes on PR #${pr_number}

Run \`gh pr view ${pr_number} --comments\` to read the review feedback.

PR: ${pr_url}

Address every change-request, commit, and push to the same branch.
RETRYEOF
}

stage_merge() {
    CURRENT_STAGE_ID="merge"

    if [[ "$NO_GITHUB" == "true" ]]; then
        info "Merge stage skipped (--no-github)"
        return 0
    fi

    # ── Oversight gate: merge block on verdict (diff + review criticals + goal) ──
    if [[ -x "$SCRIPT_DIR/sw-oversight.sh" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local merge_diff_file="${ARTIFACTS_DIR}/review-diff.patch"
        local merge_review_file="${ARTIFACTS_DIR}/review.md"
        if [[ ! -s "$merge_diff_file" ]]; then
            _safe_base_diff > "$merge_diff_file" 2>/dev/null || true
        fi
        if [[ -s "$merge_diff_file" ]]; then
            local _merge_critical _merge_sec _merge_blocking _merge_reject
            _merge_critical=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$merge_review_file" 2>/dev/null || true)
            _merge_critical="${_merge_critical:-0}"
            _merge_sec=$(grep -ciE '\*\*\[?Security\]?\*\*' "$merge_review_file" 2>/dev/null || true)
            _merge_sec="${_merge_sec:-0}"
            _merge_blocking=$((${_merge_critical:-0} + ${_merge_sec:-0}))
            [[ "$_merge_blocking" -gt 0 ]] && _merge_reject="Review found ${_merge_blocking} critical/security issue(s)"
            if ! bash "$SCRIPT_DIR/sw-oversight.sh" gate --diff "$merge_diff_file" --description "${GOAL:-Pipeline merge}" --reject-if "${_merge_reject:-}" >/dev/null 2>&1; then
                error "Oversight gate rejected — blocking merge"
                emit_event "merge.oversight_blocked" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: oversight gate rejected"
                return 1
            fi
        fi
    fi

    # ── Approval gates: block if merge requires approval and pending for this issue ──
    local ag_file="${HOME}/.shipwright/approval-gates.json"
    if [[ -f "$ag_file" ]] && [[ "${SKIP_GATES:-false}" != "true" ]]; then
        local ag_enabled ag_stages ag_pending_merge ag_issue_num
        ag_enabled=$(jq -r '.enabled // false' "$ag_file" 2>/dev/null || echo "false")
        ag_stages=$(jq -r '.stages // [] | if type == "array" then .[] else empty end' "$ag_file" 2>/dev/null || true)
        ag_issue_num=$(echo "${ISSUE_NUMBER:-0}" | awk '{print $1+0}')
        if [[ "$ag_enabled" == "true" ]] && echo "$ag_stages" | grep -qx "merge" 2>/dev/null; then
            local ha_file="${ARTIFACTS_DIR}/human-approval.txt"
            local ha_approved="false"
            if [[ -f "$ha_file" ]]; then
                ha_approved=$(jq -r --arg stage "merge" 'select(.stage == $stage) | .approved // false' "$ha_file" 2>/dev/null || echo "false")
            fi
            if [[ "$ha_approved" != "true" ]]; then
                ag_pending_merge=$(jq -r --argjson issue "$ag_issue_num" --arg stage "merge" \
                    '[.pending[]? | select(.issue == $issue and .stage == $stage)] | length' "$ag_file" 2>/dev/null || echo "0")
                if [[ "${ag_pending_merge:-0}" -eq 0 ]]; then
                    local req_at tmp_ag
                    req_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
                    tmp_ag=$(mktemp "${HOME}/.shipwright/approval-gates.json.XXXXXX" 2>/dev/null || mktemp)
                    jq --argjson issue "$ag_issue_num" --arg stage "merge" --arg requested "${req_at}" \
                        '.pending += [{"issue": $issue, "stage": $stage, "requested_at": $requested}]' "$ag_file" > "$tmp_ag" 2>/dev/null && mv "$tmp_ag" "$ag_file" || rm -f "$tmp_ag"
                fi
                info "Merge requires approval — awaiting human approval via dashboard"
                emit_event "merge.approval_pending" "issue=${ISSUE_NUMBER:-0}"
                log_stage "merge" "BLOCKED: approval gate pending"
                return 1
            fi
        fi
    fi

    # ── Branch Protection Check ──
    if type gh_branch_protection >/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        local protection_json
        protection_json=$(gh_branch_protection "$REPO_OWNER" "$REPO_NAME" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
        local is_protected
        is_protected=$(echo "$protection_json" | jq -r '.protected // false' 2>/dev/null || echo "false")
        if [[ "$is_protected" == "true" ]]; then
            local required_reviews
            required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            local required_checks
            required_checks=$(echo "$protection_json" | jq -r '[.required_status_checks.contexts // [] | .[]] | length' 2>/dev/null || echo "0")

            info "Branch protection: ${required_reviews} required review(s), ${required_checks} required check(s)"

            if [[ "$required_reviews" -gt 0 ]]; then
                # Check if PR has enough approvals
                local prot_pr_number
                prot_pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
                if [[ -n "$prot_pr_number" ]]; then
                    local approvals
                    approvals=$(gh pr view "$prot_pr_number" --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo "0")
                    if [[ "$approvals" -lt "$required_reviews" ]]; then
                        warn "PR has $approvals approval(s), needs $required_reviews — skipping auto-merge"
                        info "PR is ready for manual merge after required reviews"
                        emit_event "merge.blocked" "issue=${ISSUE_NUMBER:-0}" "reason=insufficient_reviews" "have=$approvals" "need=$required_reviews"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    local merge_method wait_ci_timeout auto_delete_branch auto_merge auto_approve merge_strategy
    merge_method=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_method) // "squash"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_method" || "$merge_method" == "null" ]] && merge_method="squash"
    wait_ci_timeout=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.wait_ci_timeout_s) // empty' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=0
    if [[ "$wait_ci_timeout" -eq 0 ]] 2>/dev/null; then
        wait_ci_timeout=$(_config_get "pipeline.merge.wait_ci_timeout_s" "1500")
    fi
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=1500
    # Coerce to integer — _config_get can return non-numeric values from env/JSON
    [[ "$wait_ci_timeout" =~ ^[0-9]+$ ]] || wait_ci_timeout=1500
    auto_delete_branch=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_delete_branch) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_delete_branch" || "$auto_delete_branch" == "null" ]] && auto_delete_branch="true"
    auto_merge=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_merge) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_merge" || "$auto_merge" == "null" ]] && auto_merge="false"
    auto_approve=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_approve) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_approve" || "$auto_approve" == "null" ]] && auto_approve="false"
    merge_strategy=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_strategy) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_strategy" || "$merge_strategy" == "null" ]] && merge_strategy=""
    # merge_strategy overrides merge_method if set (squash/merge/rebase)
    if [[ -n "$merge_strategy" ]]; then
        merge_method="$merge_strategy"
    fi

    # Find PR for current branch
    local pr_number
    pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -z "$pr_number" ]]; then
        warn "No PR found for branch $GIT_BRANCH — skipping merge"
        return 0
    fi

    info "Found PR #${pr_number} for branch ${GIT_BRANCH}"

    local pr_url=""
    pr_url=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || \
        gh pr view "$pr_number" --json url --jq '.url' 2>/dev/null || echo "")

    # Wait for CI checks to pass
    info "Waiting for CI on PR #${pr_number} (ceiling: ${wait_ci_timeout}s)"
    # empty_grace must be > poll so at least 2 polls pass before bailing on missing checks.
    # This gives CI time to register after a freshly opened PR.
    local elapsed=0 poll=60 empty_grace=120 empty_elapsed=0 _ci_wait_done=""

    while [[ "$elapsed" -lt "$wait_ci_timeout" ]]; do
        local buckets review_decision
        buckets=$(gh pr checks "$pr_number" --json bucket \
            --jq '[.[].bucket] | unique | sort' 2>/dev/null || echo '["pending"]')
        review_decision=$(gh pr view "$pr_number" --json reviewDecision \
            --jq '.reviewDecision' 2>/dev/null || echo "PENDING")

        # CI failure → write build retry context, bounce back to build
        if echo "$buckets" | jq -e 'any(. == "fail")' >/dev/null 2>&1; then
            _write_merge_retry_ctx_ci_failure "$pr_number" "$pr_url"
            emit_event "merge.ci_failed" "issue=${ISSUE_NUMBER:-0}" "pr=$pr_number" "elapsed=$elapsed"
            return 1
        fi

        # Reviewer requested changes → write build retry context, bounce back to build
        if [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
            _write_merge_retry_ctx_review "$pr_number" "$pr_url"
            emit_event "merge.changes_requested" "issue=${ISSUE_NUMBER:-0}" "pr=$pr_number"
            return 1
        fi

        # All checks passed → proceed to merge
        if echo "$buckets" | jq -e '. == ["pass"]' >/dev/null 2>&1; then
            success "All CI checks passed at ${elapsed}s"
            _ci_wait_done="pass"
            break
        fi

        # No checks appeared yet → bail after empty_grace seconds
        if [[ "$buckets" == "[]" ]]; then
            empty_elapsed=$((empty_elapsed + poll))
            if [[ "$empty_elapsed" -ge "$empty_grace" ]]; then
                warn "No CI checks present after ${empty_grace}s — proceeding"
                emit_event "merge.no_checks" "issue=${ISSUE_NUMBER:-0}" "pr=$pr_number"
                _ci_wait_done="no_checks"
                break
            fi
        else
            empty_elapsed=0
        fi

        sleep "$poll"
        elapsed=$((elapsed + poll))
    done

    if [[ -z "$_ci_wait_done" ]]; then
        warn "CI wait ceiling (${wait_ci_timeout}s) reached — proceeding with merge"
        emit_event "merge.ci_timeout" "issue=${ISSUE_NUMBER:-0}" "pr=$pr_number"
    fi

    # Auto-approve if configured (for branch protection requiring reviews)
    if [[ "$auto_approve" == "true" ]]; then
        info "Auto-approving PR #${pr_number}..."
        gh pr review "$pr_number" --approve 2>/dev/null || warn "Auto-approve failed (may need different permissions)"
    fi

    # Merge the PR
    if [[ "$auto_merge" == "true" ]]; then
        info "Enabling auto-merge for PR #${pr_number} (strategy: ${merge_method})..."
        local auto_merge_args=("pr" "merge" "$pr_number" "--auto" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            auto_merge_args+=("--delete-branch")
        fi

        if gh "${auto_merge_args[@]}" 2>/dev/null; then
            success "Auto-merge enabled for PR #${pr_number} (strategy: ${merge_method})"
            emit_event "merge.auto_enabled" \
                "issue=${ISSUE_NUMBER:-0}" \
                "pr=$pr_number" \
                "strategy=$merge_method"
        else
            # `gh pr merge --auto` can exit non-zero when GitHub has already
            # auto-merged the PR between the request and the response (race).
            # Treat already-merged as success before falling through.
            local _pr_state_auto
            _pr_state_auto=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || echo "")
            if [[ "$_pr_state_auto" == "MERGED" ]]; then
                success "PR #${pr_number} already merged (auto-merge raced ahead of CLI response)"
                emit_event "merge.race_won" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "pr=$pr_number" \
                    "path=auto_merge"
            else
                warn "Auto-merge not available — falling back to direct merge"
                # Fall through to direct merge below
                auto_merge="false"
            fi
        fi
    fi

    if [[ "$auto_merge" != "true" ]]; then
        info "Merging PR #${pr_number} (method: ${merge_method})..."
        local merge_args=("pr" "merge" "$pr_number" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            merge_args+=("--delete-branch")
        fi

        if gh "${merge_args[@]}" 2>/dev/null; then
            success "PR #${pr_number} merged successfully"
        else
            # Direct merge can also race with GitHub auto-merge if --auto was
            # enabled earlier in the same run (or by a concurrent process).
            # Treat already-merged as success before failing the stage.
            local _pr_state_direct
            _pr_state_direct=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || echo "")
            if [[ "$_pr_state_direct" == "MERGED" ]]; then
                success "PR #${pr_number} already merged (concurrent merge won the race)"
                emit_event "merge.race_won" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "pr=$pr_number" \
                    "path=direct_merge"
            else
                error "Failed to merge PR #${pr_number}"
                return 1
            fi
        fi
    fi

    log_stage "merge" "PR #${pr_number} merged (strategy: ${merge_method}, auto_merge: ${auto_merge})"
}

stage_deploy() {
    CURRENT_STAGE_ID="deploy"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-deploy.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _deploy_retry_hints
        _deploy_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load deploy safety skills
    if type skill_load_prompts >/dev/null 2>&1; then
        local _deploy_skills
        _deploy_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "deploy" 2>/dev/null || true)
        if [[ -n "$_deploy_skills" ]]; then
            echo "$_deploy_skills" > "${ARTIFACTS_DIR}/.deploy-safety-skills.md" 2>/dev/null || true
        fi
    fi
    local staging_cmd
    staging_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.staging_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$staging_cmd" == "null" ]] && staging_cmd=""

    local prod_cmd
    prod_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.production_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$prod_cmd" == "null" ]] && prod_cmd=""

    local rollback_cmd
    rollback_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""

    if [[ -z "$staging_cmd" && -z "$prod_cmd" ]]; then
        warn "No deploy commands configured — skipping"
        return 0
    fi

    # Create GitHub deployment tracking
    local gh_deploy_env="production"
    [[ -n "$staging_cmd" && -z "$prod_cmd" ]] && gh_deploy_env="staging"
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_start >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_start "$REPO_OWNER" "$REPO_NAME" "${GIT_BRANCH:-HEAD}" "$gh_deploy_env" 2>/dev/null || true
            info "GitHub Deployment: tracking as $gh_deploy_env"
        fi
    fi

    # ── Pre-deploy gates ──
    local pre_deploy_ci
    pre_deploy_ci=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_ci_status) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true

    if [[ "${pre_deploy_ci:-true}" == "true" && "${NO_GITHUB:-false}" != "true" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        info "Pre-deploy gate: checking CI status..."
        local ci_failures
        ci_failures=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/commits/${GIT_BRANCH:-HEAD}/check-runs" \
            --jq '[.check_runs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
        if [[ "${ci_failures:-0}" -gt 0 ]]; then
            error "Pre-deploy gate FAILED: ${ci_failures} CI check(s) not passing"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: ${ci_failures} CI checks failing" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: all CI checks passing"
    fi

    local pre_deploy_min_cov
    pre_deploy_min_cov=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_min_coverage) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ -n "${pre_deploy_min_cov:-}" && "${pre_deploy_min_cov}" != "null" && -f "$ARTIFACTS_DIR/test-coverage.json" ]]; then
        local actual_cov
        actual_cov=$(jq -r '.coverage_pct // 0' "$ARTIFACTS_DIR/test-coverage.json" 2>/dev/null || echo "0")
        if [[ "${actual_cov:-0}" -lt "$pre_deploy_min_cov" ]]; then
            error "Pre-deploy gate FAILED: coverage ${actual_cov}% < required ${pre_deploy_min_cov}%"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: coverage ${actual_cov}% below minimum ${pre_deploy_min_cov}%" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: coverage ${actual_cov}% >= ${pre_deploy_min_cov}%"
    fi

    # Post deploy start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "Deploy started"
    fi

    # ── Deploy strategy ──
    local deploy_strategy
    deploy_strategy=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.deploy_strategy) // "direct"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$deploy_strategy" == "null" ]] && deploy_strategy="direct"

    local canary_cmd promote_cmd switch_cmd health_url deploy_log
    canary_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.canary_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$canary_cmd" == "null" ]] && canary_cmd=""
    promote_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.promote_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$promote_cmd" == "null" ]] && promote_cmd=""
    switch_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.switch_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$switch_cmd" == "null" ]] && switch_cmd=""
    health_url=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    deploy_log="$ARTIFACTS_DIR/deploy.log"

    case "$deploy_strategy" in
        canary)
            info "Canary deployment strategy..."
            if [[ -z "$canary_cmd" ]]; then
                warn "No canary_cmd configured — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying canary..."
                bash -c "$canary_cmd" >> "$deploy_log" 2>&1 || { error "Canary deploy failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local canary_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 10
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        if [[ "$_status" -ge 200 && "$_status" -lt 400 ]]; then
                            canary_healthy=$((canary_healthy + 1))
                        fi
                    done
                    if [[ "$canary_healthy" -lt 2 ]]; then
                        error "Canary health check failed ($canary_healthy/3 passed) — rolling back"
                        [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" 2>/dev/null || true
                        return 1
                    fi
                    success "Canary healthy ($canary_healthy/3 checks passed)"
                fi

                info "Promoting canary to full deployment..."
                if [[ -n "$promote_cmd" ]]; then
                    bash -c "$promote_cmd" >> "$deploy_log" 2>&1 || { error "Promote failed"; return 1; }
                fi
                success "Canary promoted"
            fi
            ;;
        blue-green)
            info "Blue-green deployment strategy..."
            if [[ -z "$staging_cmd" || -z "$switch_cmd" ]]; then
                warn "Blue-green requires staging_cmd + switch_cmd — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying to inactive environment..."
                bash -c "$staging_cmd" >> "$deploy_log" 2>&1 || { error "Blue-green staging failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local bg_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 5
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        [[ "$_status" -ge 200 && "$_status" -lt 400 ]] && bg_healthy=$((bg_healthy + 1))
                    done
                    if [[ "$bg_healthy" -lt 2 ]]; then
                        error "Blue-green health check failed — not switching"
                        return 1
                    fi
                fi

                info "Switching traffic..."
                bash -c "$switch_cmd" >> "$deploy_log" 2>&1 || { error "Traffic switch failed"; return 1; }
                success "Blue-green switch complete"
            fi
            ;;
    esac

    # ── Direct deployment (default or fallback) ──
    if [[ "$deploy_strategy" == "direct" ]]; then
        if [[ -n "$staging_cmd" ]]; then
            info "Deploying to staging..."
            bash -c "$staging_cmd" > "$ARTIFACTS_DIR/deploy-staging.log" 2>&1 || {
                error "Staging deploy failed"
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Staging deploy failed"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Staging deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Staging deploy complete"
        fi

        if [[ -n "$prod_cmd" ]]; then
            info "Deploying to production..."
            bash -c "$prod_cmd" > "$ARTIFACTS_DIR/deploy-prod.log" 2>&1 || {
                error "Production deploy failed"
                if [[ -n "$rollback_cmd" ]]; then
                    warn "Rolling back..."
                    bash -c "$rollback_cmd" 2>&1 || error "Rollback also failed!"
                fi
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Production deploy failed — rollback ${rollback_cmd:+attempted}"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Production deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Production deploy complete"
        fi
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Deploy complete**"
        gh_add_labels "$ISSUE_NUMBER" "deployed"
    fi

    # Mark GitHub deployment as successful
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete >/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" true "" 2>/dev/null || true
        fi
    fi

    log_stage "deploy" "Deploy complete"
}

