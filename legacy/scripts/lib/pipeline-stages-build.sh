# pipeline-stages-build.sh — test_first, build, test stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_BUILD_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_BUILD_LOADED=1

stage_test_first() {
    CURRENT_STAGE_ID="test_first"
    info "Generating tests from requirements (TDD mode)"

    local plan_file="${ARTIFACTS_DIR}/plan.md"
    local goal_file="${PROJECT_ROOT}/.claude/goal.md"
    local requirements=""
    if [[ -f "$plan_file" ]]; then
        requirements=$(cat "$plan_file" 2>/dev/null || true)
    elif [[ -f "$goal_file" ]]; then
        requirements=$(cat "$goal_file" 2>/dev/null || true)
    else
        requirements="${GOAL:-}: ${ISSUE_BODY:-}"
    fi

    # ── Semantic recall: find similar past TDD test generations ──────────────
    local tdd_context=""
    if declare -f ruflo_recall_similar_outcomes >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _recall_requirements _recall_query
        _recall_requirements=$(printf '%s' "$requirements" | tr '\n' ' ' | cut -c1-800 2>/dev/null || true)
        _recall_query="${ISSUE_LABELS:-}"
        [[ -n "$_recall_requirements" ]] && _recall_query="${_recall_query:+${_recall_query}; }requirements: ${_recall_requirements}"
        tdd_context=$(ruflo_recall_similar_outcomes "${TASK_TYPE:-feature}" "$_recall_query" 2>/dev/null) || true
        tdd_context=$(printf '%.2000s' "${tdd_context:-}")
    fi

    local tdd_prompt="You are writing tests BEFORE implementation (TDD).

Based on the following plan/requirements, generate test files that define the expected behavior. These tests should FAIL initially (since the implementation doesn't exist yet) but define the correct interface and behavior.

Requirements:
${requirements}

Instructions:
1. Create test files for each component mentioned in the plan
2. Tests should verify the PUBLIC interface and expected behavior
3. Include edge cases and error handling tests
4. Tests should be runnable with the project's test framework
5. Mark tests that need implementation with clear TODO comments
6. Do NOT write implementation code — only tests

Output format: For each test file, use a fenced code block with the file path as the language identifier (e.g. \`\`\`tests/auth.test.ts):
\`\`\`path/to/test.test.ts
// file content
\`\`\`

Create files in the appropriate project directories (e.g. tests/, __tests__/, src/**/*.test.ts) per project convention."
    if [[ -n "$tdd_context" ]]; then
        tdd_prompt="${tdd_prompt}

## Similar Past Test Generations
From previous pipelines with the same task type:
${tdd_context}"
    fi

    local model="${CLAUDE_MODEL:-${MODEL:-sonnet}}"
    [[ -z "$model" || "$model" == "null" ]] && model="sonnet"

    local output=""
    output=$(echo "$tdd_prompt" | _timeout 120 claude --print --disallowed-tools "EnterPlanMode,ExitPlanMode" --model "$model" 2>/dev/null) || {
        warn "TDD test generation failed, falling back to standard build"
        return 1
    }

    # Parse output: extract fenced code blocks and write to files
    local wrote_any=false
    local written_files=""
    local block_path="" in_block=false block_content=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\`\`\`([a-zA-Z0-9_/\.\-]+)$ ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    written_files="${written_files:+${written_files},}${block_path}"
                    info "  Wrote: $block_path"
                fi
            fi
            block_path="${BASH_REMATCH[1]}"
            block_content=""
            in_block=true
        elif [[ "$line" == "\`\`\`" && "$in_block" == "true" ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    written_files="${written_files:+${written_files},}${block_path}"
                    info "  Wrote: $block_path"
                fi
            fi
            block_path=""
            block_content=""
            in_block=false
        elif [[ "$in_block" == "true" && -n "$block_path" ]]; then
            [[ -n "$block_content" ]] && block_content="${block_content}"$'\n'
            block_content="${block_content}${line}"
        fi
    done <<< "$output"

    # Flush last block if unclosed
    if [[ -n "$block_path" && -n "$block_content" ]]; then
        local out_file="${PROJECT_ROOT}/${block_path}"
        local out_dir
        out_dir=$(dirname "$out_file")
        mkdir -p "$out_dir" 2>/dev/null || true
        if echo "$block_content" > "$out_file" 2>/dev/null; then
            wrote_any=true
            written_files="${written_files:+${written_files},}${block_path}"
            info "  Wrote: $block_path"
        fi
    fi

    if [[ "$wrote_any" == "true" ]]; then
        if (cd "$PROJECT_ROOT" && git diff --name-only 2>/dev/null | grep -qE 'test|spec'); then
            safe_git_stage
            git commit -m "test: TDD - define expected behavior before implementation" 2>/dev/null || true
            emit_event "tdd.tests_generated" "{\"stage\":\"test_first\"}"
        fi
        success "TDD tests generated"
    else
        warn "No test files extracted from TDD output — check format"
    fi

    # ── Store TDD generation outcome for future recall ────────────────────────
    # Uses the learning-<repo_hash> namespace so future ruflo_recall_similar_outcomes
    # calls (which query that namespace) can retrieve these stored outcomes.
    if declare -f ruflo_store >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1 && \
       ruflo_available && [[ "$wrote_any" == "true" ]]; then
        if [[ -z "${SHIPWRIGHT_PIPELINE_ID:-}" ]]; then
            warn "SHIPWRIGHT_PIPELINE_ID unset — skipping TDD outcome storage to prevent key collision"
        else
            local _tdd_ns_hash
            _tdd_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
            if [[ -n "$_tdd_ns_hash" ]]; then
                local tdd_key="test_first-${SHIPWRIGHT_PIPELINE_ID}-$(date +%s)"
                local tdd_outcome
                tdd_outcome=$(jq -n --arg goal "${GOAL:-}" --arg task "${TASK_TYPE:-feature}" \
                    --arg files "${written_files:-}" \
                    '{goal: $goal, task_type: $task, tests_generated: true, files_written: $files}' 2>/dev/null || echo '{}')
                ruflo_store "$tdd_key" "$tdd_outcome" \
                    "learning-${_tdd_ns_hash}" \
                    "tdd,test_first,${TASK_TYPE:-feature}" 2>/dev/null || true
            fi
        fi
    fi

    return 0
}

_build_branch_progress() {
    # compound_quality-aware diff base.
    # OUTER_STAGE_START_COMMIT missing from old state files → falls back to merge-base silently.
    local _base_branch _merge_base _progress
    _base_branch="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||' || true)"
    [[ -z "$_base_branch" || "$_base_branch" == "HEAD" ]] && _base_branch="main"

    if [[ "${OUTER_STAGE:-}" == "compound_quality" && -n "${OUTER_STAGE_START_COMMIT:-}" ]]; then
        _merge_base="$OUTER_STAGE_START_COMMIT"
    else
        _merge_base="$(git merge-base "origin/${_base_branch}" HEAD 2>/dev/null \
            || git merge-base "${_base_branch}" HEAD 2>/dev/null || true)"
        # Fall back to root commit when branch-name lookup fails (no remote, unusual default branch name)
        [[ -z "$_merge_base" ]] && \
            _merge_base="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
    fi

    if [[ -z "$_merge_base" ]]; then
        echo "No changes committed to this branch yet (first pass)."
        return 0
    fi

    _progress="$(git diff --name-status "${_merge_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths | head -40 || true)"
    if [[ -z "$_progress" ]]; then
        echo "No changes committed to this branch yet (first pass)."
    else
        printf '## Branch starting state (files changed before this build pass)\n%s\n' "$_progress"
    fi
}

stage_build() {
    CURRENT_STAGE_ID="build"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-build.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _build_retry_hints
        _build_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"
    local dod_file="$ARTIFACTS_DIR/dod.md"
    local loop_args=()

    # Memory integration — inject goal-aware context if memory system has prior runs.
    # No fallback: if the focused search returns nothing, the block is omitted entirely.
    # A goal-agnostic fallback was removed (see PR fix/cold-pipeline-memory-injection)
    # because it injected unrelated failure history on cold (first-run) issues.
    local memory_context=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "build stage for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi

    # Build clean goal (no synthesis context)
    local clean_goal
    clean_goal="$GOAL"

    # Build synthesized context separately (Layer A: sidecar delivery)
    local build_context_body
    build_context_body=$(_pipeline_compact_goal "$GOAL" "$plan_file" "$design_file")

    # TDD: when test_first ran, tell build to make existing tests pass
    if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
        build_context_body="${build_context_body}

IMPORTANT (TDD mode): Test files already exist and define the expected behavior. Write implementation code to make ALL tests pass. Do not delete or modify the test files."
    fi

    # Inject memory context
    if [[ -n "$memory_context" ]]; then
        build_context_body="${build_context_body}

Historical context (lessons from previous pipelines):
${memory_context}"
    fi

    # Inject cross-pipeline discoveries for build stage
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        local build_discoveries
        DISCOVERY_FILE_PATTERNS="${DISCOVERY_FILE_PATTERNS:-src/*,*.ts,*.tsx,*.js,*.jsx,*.mjs,*.cjs,*.sh,*.bash,*.zsh,*.swift,*.m,*.mm,*.h,*.java,*.kt,*.py,*.rb,*.go,*.rs,*.cs,*.cpp,*.cc,*.c,*.vue,*.svelte}"
        build_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "$DISCOVERY_FILE_PATTERNS" 2>/dev/null | head -20 || true)
        if [[ -n "$build_discoveries" ]]; then
            build_context_body="${build_context_body}

Discoveries from other pipelines:
${build_discoveries}"
        fi
    fi

    # Inject branch starting state
    local _branch_progress
    _branch_progress="$(_build_branch_progress 2>/dev/null || true)"
    if [[ -n "$_branch_progress" ]]; then
        build_context_body="${build_context_body}

${_branch_progress}"
    fi

    # Inject scope guardrail from design.md (T1.2c).
    # Reads the machine-parseable ```scope block and prepends a SCOPE constraint
    # to the build context so the agent knows which files it is allowed to touch.
    if declare -f _extract_scope_from_design >/dev/null 2>&1; then
        local _scope_list
        _scope_list=$(_extract_scope_from_design "$ARTIFACTS_DIR" 2>/dev/null)
        if [[ -n "$_scope_list" ]]; then
            local _scope_block
            _scope_block=$(printf '%s\n' "$_scope_list" | sed 's/^/  - /')
            build_context_body="SCOPE — modify ONLY these files (from design.md):
${_scope_block}
Do NOT modify any file outside this list. If an out-of-scope change is genuinely
required, STOP and emit: <<<LOOP:SCOPE_ESCALATION:reason>>>
The design will be updated by a human before you proceed.

${build_context_body}"
            emit_event "build.scope_injected" "issue=${ISSUE_NUMBER:-0}" "file_count=$(echo "$_scope_list" | wc -l | tr -d ' ')"
        fi
    fi

    # Validate task list before loop start — clean up stale or malformed files.
    # Task content is injected dynamically each iteration by compose_task_section()
    # in loop-iteration.sh; do not inject the full file into the goal here.
    # Goal-based pipelines (no GITHUB_ISSUE) skip issue validation — preserve the file.
    if [[ -s "$TASKS_FILE" ]]; then
        local current_issue; current_issue=$(echo "${GITHUB_ISSUE:-}" | tr -d '#' | xargs)
        if [[ -n "$current_issue" ]]; then
            local tasks_issue
            if ! tasks_issue=$(extract_issue_from_tasks_file "$TASKS_FILE"); then
                warn "Malformed pipeline-tasks.md (missing Issue header) — removing before loop start"
                rm -f "$TASKS_FILE"
            elif [[ "$tasks_issue" != "$current_issue" ]]; then
                warn "Removing stale pipeline-tasks.md (was for issue $tasks_issue, current $current_issue)"
                rm -f "$TASKS_FILE"
            fi
        fi
    fi

    # Inject file hotspots from GitHub intelligence
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_file_change_frequency >/dev/null 2>&1; then
        local build_hotspots
        build_hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
        if [[ -n "$build_hotspots" ]]; then
            build_context_body="${build_context_body}

File hotspots (most frequently changed — review these carefully):
${build_hotspots}"
        fi
    fi

    # Inject security alerts context
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_security_alerts >/dev/null 2>&1; then
        local build_alerts
        build_alerts=$(gh_security_alerts 2>/dev/null | head -3 || true)
        if [[ -n "$build_alerts" ]]; then
            build_context_body="${build_context_body}

Active security alerts (do not introduce new vulnerabilities):
${build_alerts}"
        fi
    fi

    # Inject coverage baseline
    local repo_hash_build
    repo_hash_build=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local coverage_file_build="${HOME}/.shipwright/baselines/${repo_hash_build}/coverage.json"
    if [[ -f "$coverage_file_build" ]]; then
        local coverage_baseline
        coverage_baseline=$(jq -r '.coverage_percent // empty' "$coverage_file_build" 2>/dev/null || true)
        if [[ -n "$coverage_baseline" ]]; then
            build_context_body="${build_context_body}

Coverage baseline: ${coverage_baseline}% — do not decrease coverage."
        fi
    fi

    # Predictive: inject prevention hints when risk/memory patterns suggest build-stage failures
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local issue_json_build="{}"
        [[ -n "${ISSUE_NUMBER:-}" ]] && issue_json_build=$(jq -n --arg title "${GOAL:-}" --arg num "${ISSUE_NUMBER:-}" '{title: $title, number: $num}')
        local prevention_text
        prevention_text=$(bash "$SCRIPT_DIR/sw-predictive.sh" inject-prevention "build" "$issue_json_build" 2>/dev/null || true)
        if [[ -n "$prevention_text" ]]; then
            build_context_body="${build_context_body}

${prevention_text}"
        fi
    fi

    # Inject skill prompts for build stage
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "build" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        build_context_body="${build_context_body}

## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    # ── Ruflo: recall similar build outcomes for historical context ────────────
    if declare -f ruflo_recall_similar_outcomes >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        local _build_recall_query _build_recall_ctx
        _build_recall_query="${GOAL:-}"
        if [[ -n "${ISSUE_LABELS:-}" ]]; then
            # Strip characters that could malform the query if the recall system
            # treats the query as structured/DSL input (e.g. quotes, semicolons).
            local _safe_labels
            _safe_labels=$(printf '%s' "${ISSUE_LABELS}" | tr -d '";\`\\')
            _build_recall_query="${_build_recall_query}; labels: ${_safe_labels}"
        fi
        _build_recall_ctx=""
        # ruflo_recall_similar_outcomes is fail-open: it always exits 0 and prints an
        # empty string when the underlying search fails. The || true is defensive only.
        _build_recall_ctx=$(ruflo_recall_similar_outcomes "${TASK_TYPE:-feature}" "$_build_recall_query" 2>/dev/null) || true
        # Sanitize recall output before injecting into the prompt:
        # 1. Strip entire lines starting with '#' (markdown headers). Removing the whole
        #    line is safer than stripping only the prefix — bare header text is still an
        #    instruction fragment that Claude could interpret as a directive.
        #    Use sed (not grep -v) so the pipeline exits 0 even when all lines are filtered.
        # 2. Strip C0 control characters (except HT \011 and LF \012) to prevent
        #    escape-sequence injection from a compromised memory store.
        # 3. Truncate to 2000 chars to prevent context flooding.
        local _raw_recall_ctx="$_build_recall_ctx"
        _build_recall_ctx=$(printf '%s\n' "${_build_recall_ctx}" \
            | sed '/^#/d' \
            | tr -d '\000-\010\013-\037\177')
        _build_recall_ctx=$(printf '%.2000s' "${_build_recall_ctx}")
        # Warn if sanitization stripped any content — this indicates a compromised
        # or malformed memory store entry and may warrant operator investigation.
        if [[ "$_raw_recall_ctx" != "$_build_recall_ctx" && -n "$_raw_recall_ctx" ]]; then
            warn "Ruflo: recall output was sanitized before injection (potential injection attempt or malformed data)"
        fi
        # Validate threshold: must be a non-negative integer; fall back to 50 if not.
        # Use :-50 in both places so an unset variable doesn't trigger nounset (set -u).
        local _ruflo_min_len
        if [[ "${SHIPWRIGHT_RUFLO_RECALL_MIN_LEN:-50}" =~ ^[0-9]+$ ]]; then
            _ruflo_min_len="${SHIPWRIGHT_RUFLO_RECALL_MIN_LEN:-50}"
        else
            _ruflo_min_len=50
        fi
        # Length gate uses the RAW (pre-sanitization) length so that stripping
        # injected markdown headers doesn't cause substantive content to fall
        # below the threshold. Sanitization can only remove content, so if the
        # raw result is too short, the sanitized result will be too.
        if [[ -n "$_build_recall_ctx" && "${#_raw_recall_ctx}" -ge "$_ruflo_min_len" ]]; then
            build_context_body="${build_context_body}

## Historical Build Context
${_build_recall_ctx}"
            info "Ruflo: injected historical build context (${#_build_recall_ctx} chars)"
        else
            if [[ -n "$_build_recall_ctx" ]]; then
                info "Ruflo: recall result too short to be useful (${#_raw_recall_ctx} chars raw, min=${_ruflo_min_len}) — skipping injection"
            else
                info "Ruflo: no similar outcomes found yet for this repo. Outcomes accumulate across pipeline runs in the repo and issue namespaces."
            fi
        fi
    fi

    # Seam (c): redact out-of-scope paths from build_context_body before writing to disk.
    # Memory-context and historical recall may reference paths from previous pipeline runs
    # in different scopes; strip them now so the loop agent never sees them.
    if declare -f _redact_paths_outside_scope >/dev/null 2>&1 && \
       declare -f _extract_scope_from_design >/dev/null 2>&1; then
        local _bld_scope_allowlist=""
        _bld_scope_allowlist=$(_extract_scope_from_design "$ARTIFACTS_DIR" 2>/dev/null || true)
        if [ -n "$_bld_scope_allowlist" ]; then
            build_context_body=$(_redact_paths_outside_scope "$build_context_body" \
                "$_bld_scope_allowlist" "build_context" "${COMPOUND_QUALITY_CYCLE:-0}" \
                2>/dev/null || printf '%s' "$build_context_body")
        fi
    fi

    # Layer A: Write synthesized context to sidecar (atomic write)
    local _ctx_file="${ARTIFACTS_DIR}/build-context.md"
    local _ctx_tmp="${_ctx_file}.tmp.$$"
    printf '%s\n' "$build_context_body" > "$_ctx_tmp"
    mv "$_ctx_tmp" "$_ctx_file" || { error "Failed to write build context to ${_ctx_file}"; return 1; }
    info "Build context written to ${_ctx_file} ($(wc -c < "$_ctx_file") bytes)"

    # Post branch starting state once per pipeline run (not on every compound_quality re-entry).
    # Reuse _branch_progress already computed above — no second git call.
    if [[ -z "${_BRANCH_STATE_POSTED:-}" ]] && \
       [[ -n "${ISSUE_NUMBER:-}" ]] && type gh_comment_issue >/dev/null 2>&1; then
        if [[ -n "${_branch_progress:-}" ]] && [[ "$_branch_progress" != *"No changes committed"* ]]; then
            gh_comment_issue "$ISSUE_NUMBER" \
                "$(printf '### Branch Starting State\n\n```\n%s\n```' "$_branch_progress")"
            _BRANCH_STATE_POSTED=1
        fi
    fi

    # Pass clean goal to loop (not enriched with context)
    loop_args+=("$clean_goal")
    loop_args+=(--context-file "$_ctx_file")

    # Build loop args from pipeline config + CLI overrides
    CURRENT_STAGE_ID="build"

    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect if still empty
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    # Discover additional test commands (subdirectories, extra scripts)
    local additional_cmds=()
    if type detect_test_commands >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && additional_cmds+=("$_cmd")
        done < <(detect_test_commands 2>/dev/null | tail -n +2)
    fi

    local max_iter
    max_iter=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.max_iterations) // 20' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_iter" || "$max_iter" == "null" ]] && max_iter=20
    # CLI --max-iterations override (from CI strategy engine)
    [[ -n "${MAX_ITERATIONS_OVERRIDE:-}" ]] && max_iter="$MAX_ITERATIONS_OVERRIDE"

    local agents="${AGENTS}"
    if [[ -z "$agents" ]]; then
        agents=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.agents) // .defaults.agents // 1' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$agents" || "$agents" == "null" ]] && agents=1
    fi

    # Intelligence: suggest parallelism if design indicates independent work
    if [[ "${agents:-1}" -le 1 ]] && [[ -s "$ARTIFACTS_DIR/design.md" ]]; then
        local design_lower
        design_lower=$(tr '[:upper:]' '[:lower:]' < "$ARTIFACTS_DIR/design.md" 2>/dev/null || true)
        if echo "$design_lower" | grep -qE 'independent (files|modules|components|services)|separate (modules|packages|directories)|parallel|no shared state'; then
            info "Design mentions independent modules — consider --agents 2 for parallelism"
            emit_event "build.parallelism_suggested" "issue=${ISSUE_NUMBER:-0}" "current_agents=$agents"
        fi
    fi

    local audit
    audit=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.audit) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    local quality
    quality=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.quality_gates) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    local build_model="${MODEL}"
    if [[ -z "$build_model" ]]; then
        build_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$build_model" || "$build_model" == "null" ]] && build_model="opus"
    fi
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        build_model="$CLAUDE_MODEL"
    fi

    # Recruit-powered model selection (when no explicit override)
    if [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
        local _recruit_goal="${GOAL:-}"
        if [[ -n "$_recruit_goal" ]]; then
            local _recruit_match
            _recruit_match=$(bash "$SCRIPT_DIR/sw-recruit.sh" match --json "$_recruit_goal" 2>/dev/null) || true
            if [[ -n "$_recruit_match" ]]; then
                local _recruit_model
                _recruit_model=$(echo "$_recruit_match" | jq -r '.model // ""' 2>/dev/null) || true
                if [[ -n "$_recruit_model" && "$_recruit_model" != "null" && "$_recruit_model" != "" ]]; then
                    info "Recruit recommends model: ${CYAN}${_recruit_model}${RESET} for this task"
                    build_model="$_recruit_model"
                fi
            fi
        fi
    fi

    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && loop_args+=(--test-cmd "$test_cmd")
    for _extra_tc in "${additional_cmds[@]+"${additional_cmds[@]}"}"; do
        [[ -n "$_extra_tc" ]] && loop_args+=(--additional-test-cmds "$_extra_tc")
    done
    loop_args+=(--max-iterations "$max_iter")
    loop_args+=(--model "$build_model")
    [[ "$agents" -gt 1 ]] 2>/dev/null && loop_args+=(--agents "$agents")

    # Quality gates: always enabled in CI, otherwise from template config
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        loop_args+=(--audit --audit-agent --quality-gates)
    else
        [[ "$audit" == "true" ]] && loop_args+=(--audit --audit-agent)
        [[ "$quality" == "true" ]] && loop_args+=(--quality-gates)
    fi

    # Session restart capability
    [[ -n "${MAX_RESTARTS_OVERRIDE:-}" ]] && loop_args+=(--max-restarts "$MAX_RESTARTS_OVERRIDE")
    # Fast test cmd: CLI override > template stage config > template defaults > daemon-config.json baseline
    local _fast_test_cmd="${FAST_TEST_CMD_OVERRIDE:-}"
    if [[ -z "$_fast_test_cmd" ]]; then
        _fast_test_cmd=$(jq -r --arg id "build" \
            '(.stages[] | select(.id == $id) | .config.fast_test_cmd) // .defaults.fast_test_cmd // ""' \
            "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$_fast_test_cmd" == "null" ]] && _fast_test_cmd=""
    fi
    if [[ -z "$_fast_test_cmd" ]]; then
        local _dc_build
        if declare -f _load_daemon_config >/dev/null 2>&1; then
            _dc_build=$(_load_daemon_config)
        else
            _dc_build=$(cat "${PROJECT_ROOT:-$PWD}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
        fi
        _fast_test_cmd=$(echo "$_dc_build" | jq -r '.fast_test_cmd // ""' 2>/dev/null) || true
        [[ "$_fast_test_cmd" == "null" ]] && _fast_test_cmd=""
    fi
    [[ -n "$_fast_test_cmd" ]] && loop_args+=(--fast-test-cmd "$_fast_test_cmd")

    # Fast test interval: CLI override > template stage config > template defaults > daemon-config.json baseline
    local _fast_test_interval="${FAST_TEST_INTERVAL_OVERRIDE:-}"
    if [[ -z "$_fast_test_interval" ]]; then
        _fast_test_interval=$(jq -r --arg id "build" \
            '(.stages[] | select(.id == $id) | .config.fast_test_interval) // .defaults.fast_test_interval // ""' \
            "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$_fast_test_interval" == "null" ]] && _fast_test_interval=""
    fi
    if [[ -z "$_fast_test_interval" ]]; then
        local _dc_build_int
        if declare -f _load_daemon_config >/dev/null 2>&1; then
            _dc_build_int=$(_load_daemon_config)
        else
            _dc_build_int=$(cat "${PROJECT_ROOT:-$PWD}/.claude/daemon-config.json" 2>/dev/null || echo '{}')
        fi
        _fast_test_interval=$(echo "$_dc_build_int" | jq -r '.fast_test_interval // ""' 2>/dev/null) || true
        [[ "$_fast_test_interval" == "null" ]] && _fast_test_interval=""
    fi
    if [[ -n "$_fast_test_interval" ]]; then
        if ! [[ "$_fast_test_interval" =~ ^[1-9][0-9]*$ ]]; then
            warn "Ignoring invalid fast_test_interval='$_fast_test_interval' (expected positive integer; check template stage config, template defaults, or daemon-config.json)."
            _fast_test_interval=""
        fi
    fi
    [[ -n "$_fast_test_interval" ]] && loop_args+=(--fast-test-interval "$_fast_test_interval")

    # Definition of Done: use plan-extracted DoD if available
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    # Checkpoint resume: when pipeline resumed from build-stage checkpoint, pass --resume to loop
    if [[ "${RESUME_FROM_CHECKPOINT:-false}" == "true" && "${checkpoint_stage:-}" == "build" ]]; then
        loop_args+=(--resume)
    fi

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Without this flag, agents can't write files.
    loop_args+=(--skip-permissions)

    # Ruflo hive-mind build: when RUFLO_HIVE_BUILD=true and agents>1, try hive first.
    # Three-tier fallback: hive → single-agent → sw loop. Fail-open by design.
    if [[ "${RUFLO_HIVE_BUILD:-false}" == "true" ]] && \
       { [[ "${agents:-1}" -gt 1 ]] 2>/dev/null || false; } && \
       declare -f ruflo_execute_build_hive >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        info "Ruflo hive-mind build executor active — attempting hive build (${agents} agents)"
        if ruflo_execute_build_hive "$enriched_goal" "$max_iter"; then
            local commit_count
            commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")
            info "Ruflo hive build produced ${BOLD}$commit_count${RESET} commit(s)"
            if declare -f ruflo_store >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
                ruflo_store "stage-build-result" \
                    "Ruflo hive build: $commit_count commits, ${agents} agents. Branch: ${GIT_BRANCH:-unknown}." \
                    "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
            fi
            log_stage "build" "Ruflo hive build completed ($commit_count commits)"
            return 0
        fi
        warn "Ruflo hive build failed — falling back to single-agent or sw loop"
        emit_event "ruflo.hive_build_fallback" "reason=hive_failed"
    fi

    # Ruflo single-agent build: when RUFLO_BUILD_AGENT=true and agents=1, try ruflo first.
    # Falls back to sw loop on any failure — fail-open by design.
    if [[ "${RUFLO_BUILD_AGENT:-false}" == "true" ]] && \
       [[ "${agents:-1}" -eq 1 ]] && \
       declare -f ruflo_execute_build_single >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       ruflo_available; then
        info "Ruflo single-agent build executor active — attempting ruflo build"
        if ruflo_execute_build_single "$enriched_goal" "$max_iter"; then
            local commit_count
            commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")
            info "Ruflo build produced ${BOLD}$commit_count${RESET} commit(s)"
            if declare -f ruflo_store >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
                ruflo_store "stage-build-result" \
                    "Ruflo single-agent build: $commit_count commits. Branch: ${GIT_BRANCH:-unknown}." \
                    "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
            fi
            log_stage "build" "Ruflo build completed ($commit_count commits)"
            return 0
        fi
        warn "Ruflo build failed — falling back to sw loop"
        emit_event "ruflo.build_fallback" "reason=agent_failed"
    fi

    info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

    # Post build start to GitHub — use gh_post_progress so PROGRESS_COMMENT_ID is captured
    # for subsequent gh_update_progress calls; if a comment already exists from intake,
    # update it instead of creating a new one.
    if [[ -n "$ISSUE_NUMBER" ]]; then
        if [[ -n "${PROGRESS_COMMENT_ID:-}" ]]; then
            gh_update_progress "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
        else
            gh_post_progress "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
        fi
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
    local _build_log="${ARTIFACTS_DIR}/build.log"
    # Pre-write a header line so the file exists even if `sw loop` is killed before
    # writing anything to stdout (e.g., on a 5-hour job hard-timeout). The file is
    # read by _resolve_stage_log_path() (pipeline-state.sh:566) when subsequent
    # stages or post-mortems need the build output. Without this, hard timeouts
    # leave the diagnostic "stage build produced no log" with nothing to show.
    {
        printf '=== build.log — issue %s — run %s — started %s ===\n' \
            "${ISSUE_NUMBER:-?}" \
            "${SHIPWRIGHT_PIPELINE_ID:-?}" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$_build_log"
    export PIPELINE_JOB_ID="${PIPELINE_NAME:-pipeline-$$}"
    # Per-iteration cost sidecar (issue #87) — read by sw-loop.sh's record_iteration_cost.
    export ITER_COST_JSONL="${ARTIFACTS_DIR}/loop-iteration-costs.jsonl"
    # Export so SW_LOG_PROMPTS=github|both can post/update GitHub comments from the loop subprocess.
    export ISSUE_NUMBER="${ISSUE_NUMBER:-}"
    export PROGRESS_COMMENT_ID="${PROGRESS_COMMENT_ID:-}"
    # Export per-CI-job start epoch. Set by the workflow's "Record CI job start epoch"
    # step (.github/workflows/shipwright-pipeline.yml). Empty when running outside CI
    # (local sw pipeline) — check_time_budget falls back to LOOP_START_EPOCH.
    # Replaces PIPELINE_RUN_EPOCH export from commit 591c8e8: that field is persisted
    # across CI jobs in .claude/pipeline-state.md and is therefore an unsafe budget anchor.
    # PIPELINE_RUN_EPOCH remains in the state file for historical display only.
    export CI_JOB_START_EPOCH="${CI_JOB_START_EPOCH:-}"
    # Enable scope guard so safe_git_stage() blocks out-of-scope commits (T1.2)
    export SCOPE_GUARD_ENABLED="true"
    # Pipe stdout through `tee -a` so build.log grows incrementally — whatever the
    # loop emitted before a SIGTERM kill survives on disk for post-mortems.
    # `set +e` around the pipeline lets us read PIPESTATUS[0] for the loop's true
    # exit code instead of tee's, without errexit aborting on a non-zero loop.
    set +e
    sw loop "${loop_args[@]}" < /dev/null 2>"$_token_log" | tee -a "$_build_log"
    local _loop_exit=${PIPESTATUS[0]}
    set -e
    if [[ "$_loop_exit" -ne 0 ]]; then
        parse_claude_tokens "$_token_log"

        # Detect context exhaustion from progress file
        local _progress_file="${PWD}/.claude/loop-logs/progress.md"
        if [[ -f "$_progress_file" ]]; then
            local _prog_tests
            _prog_tests=$(grep -oE 'Tests passing: (true|false)' "$_progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
            if [[ "$_prog_tests" != "true" ]]; then
                warn "Build loop exhausted with failing tests (context exhaustion)"
                emit_event "pipeline.context_exhaustion" "issue=${ISSUE_NUMBER:-0}" "stage=build"
                # Write flag for daemon retry logic
                mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
                echo "context_exhaustion" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            fi
        fi

        error "Build loop failed"
        return 1
    fi
    parse_claude_tokens "$_token_log"

    # Read accumulated token counts from build loop (written by sw-loop.sh)
    local _loop_token_file="${PROJECT_ROOT}/.claude/loop-logs/loop-tokens.json"
    if [[ -f "$_loop_token_file" ]] && command -v jq >/dev/null 2>&1; then
        local _loop_in _loop_out _loop_cost
        _loop_in=$(jq -r '.input_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_out=$(jq -r '.output_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_cost=$(jq -r '.cost_usd // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${_loop_in:-0} ))
        TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${_loop_out:-0} ))
        if [[ -n "$_loop_cost" && "$_loop_cost" != "0" && "$_loop_cost" != "null" ]]; then
            TOTAL_COST_USD="${_loop_cost}"
        fi
        if [[ "${_loop_in:-0}" -gt 0 || "${_loop_out:-0}" -gt 0 ]]; then
            info "Build loop tokens: in=${_loop_in} out=${_loop_out} cost=\$${_loop_cost:-0}"
        fi
    fi

    # Count commits made during build
    local commit_count
    commit_count=$(_trim "$(_safe_base_log --oneline | wc -l)")
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

    # Commit quality evaluation when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
        local commit_msgs
        commit_msgs=$(_safe_base_log --format="%s" | head -20)
        local quality_score
        quality_score=$(claude --print --output-format text --disallowed-tools "EnterPlanMode,ExitPlanMode" -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

Commit messages:
${commit_msgs}" --model haiku < /dev/null 2>/dev/null || true)
        quality_score=$(echo "$quality_score" | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -n "$quality_score" ]]; then
            emit_event "build.commit_quality" \
                "issue=${ISSUE_NUMBER:-0}" \
                "score=$quality_score" \
                "commit_count=$commit_count"
            if [[ "$quality_score" -lt 40 ]] 2>/dev/null; then
                warn "Commit message quality low (score: ${quality_score}/100)"
            else
                info "Commit quality score: ${quality_score}/100"
            fi
        fi
    fi

    # Store build summary in ruflo for cross-stage context
    if declare -f ruflo_store >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
        ruflo_store "stage-build-result" \
            "Build loop completed: $commit_count commits. Branch: ${GIT_BRANCH:-unknown}." \
            "pipeline-${SHIPWRIGHT_PIPELINE_ID:-unknown}" || true
    fi

    # Store build outcome in issue namespace for future iterations (always, not just on commits).
    # Uses a stable key for no-commits outcomes so compound_quality re-entries overwrite
    # the same slot instead of accumulating (intentional last-write-wins); timestamped key
    # for success outcomes. Requires SHIPWRIGHT_PIPELINE_ID to be run-scoped (not issue-scoped)
    # for the stable key to be unique per pipeline run; the :-$$ fallback uses shell PID.
    if type ruflo_store_issue_outcome >/dev/null 2>&1; then
        local _build_ts _build_files _build_base _build_base_branch _build_status _build_key
        _build_ts="$(date +%s 2>/dev/null || echo 0)"
        if [[ "${commit_count:-0}" -gt 0 ]]; then
            _build_status="success"
            _build_key="build-${SHIPWRIGHT_PIPELINE_ID:-$$}-${_build_ts}"
        else
            _build_status="no-commits"
            _build_key="build-${SHIPWRIGHT_PIPELINE_ID:-$$}-current"
        fi
        _build_base_branch="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||' || true)"
        [[ -z "$_build_base_branch" || "$_build_base_branch" == "HEAD" ]] && _build_base_branch="main"
        if [[ "${OUTER_STAGE:-}" == "compound_quality" && -n "${OUTER_STAGE_START_COMMIT:-}" ]]; then
            _build_base="$OUTER_STAGE_START_COMMIT"
        else
            _build_base="$(git merge-base "origin/${_build_base_branch}" HEAD 2>/dev/null \
                || git merge-base "${_build_base_branch}" HEAD 2>/dev/null || echo "HEAD~1")"
        fi
        _build_files="$(git diff --name-status "${_build_base}..HEAD" -- . $(_git_excluded_pathspecs) 2>/dev/null | _filter_gitignored_paths | head -20 | tr '\n' '|' || true)"
        ruflo_store_issue_outcome \
            "$_build_key" \
            "$(jq -n --arg goal "${GOAL:-}" --arg files "$_build_files" --arg status "$_build_status" \
                '{goal:$goal,stage:"build",files_changed:$files,status:$status}' 2>/dev/null || echo '{}')" \
            "build,${TASK_TYPE:-feature}" 2>/dev/null || true
    fi

    log_stage "build" "Build loop completed ($commit_count commits)"
}

stage_test() {
    CURRENT_STAGE_ID="test"
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$test_cmd" || "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi
    if [[ -z "$test_cmd" ]]; then
        warn "No test command found — skipping test stage"
        return 0
    fi

    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    local test_log="$ARTIFACTS_DIR/test-results.log"

    info "Running tests: ${DIM}$test_cmd${RESET}"

    # ── Unique run key — accumulates history rather than overwriting ─────
    # Include PID + random suffix to prevent collisions from parallel runs
    # or rapid retries within the same second.
    local _st_run_ts
    _st_run_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%s")
    local _st_run_uid="${_st_run_ts}-$$-${RANDOM}"
    local _st_result_key="stage-test-result-${_st_run_uid}"
    # Resolve a stable, cross-run namespace via repo hash (same approach as
    # stage_test_first and ruflo_recall_similar_outcomes). pipeline-${ID} would
    # create a fresh namespace each run, making flakiness recall impossible.
    local _st_ruflo_ns=""
    if declare -f _ruflo_resolve_repo_hash >/dev/null 2>&1; then
        local _st_ns_hash
        _st_ns_hash=$(_ruflo_resolve_repo_hash 2>/dev/null) || true
        _st_ruflo_ns="${_st_ns_hash:+learning-${_st_ns_hash}}"
    fi

    # ── Recall historical flakiness patterns from ruflo ──────────────────
    local _ruflo_flakiness_ctx=""
    if declare -f ruflo_recall >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       [[ -n "$_st_ruflo_ns" ]] && \
       ruflo_available; then
        _ruflo_flakiness_ctx=$(ruflo_recall "test flakiness patterns failures" \
            "$_st_ruflo_ns" 2>/dev/null || true)
        _ruflo_flakiness_ctx=$(printf '%.2000s' "${_ruflo_flakiness_ctx:-}")
        if [[ -n "$_ruflo_flakiness_ctx" ]]; then
            info "Ruflo recall: historical test patterns found"
            info "${DIM}${_ruflo_flakiness_ctx}${RESET}"
        fi
    fi

    local test_exit=0
    bash -c "$test_cmd" > "$test_log" 2>&1 || test_exit=$?

    # ── Use recalled patterns: retry once if failure matches known flaky ──
    local _test_is_known_flaky="false"
    local _matched_flaky_pattern=""
    if [[ "$test_exit" -ne 0 && -n "$_ruflo_flakiness_ctx" ]]; then
        local _fail_excerpt
        # Capture both head (setup/infra errors) and tail (test failure summaries)
        # Most runners (jest, vitest, go test) print the failure summary at the end.
        _fail_excerpt=$({ head -20 "$test_log"; tail -40 "$test_log"; } | strip_ansi 2>/dev/null || true)
        # Extract keywords: require 8+ chars to avoid matching common words
        # like "after", "error", "tests" that appear in most failure output.
        # Also filter out a stop-list of generic terms that cause false positives.
        local _kw _st_stopwords="received|expected|function|actually|returned|argument|property|undefined|contains|resource|standard|platform"
        while IFS= read -r _kw; do
            [[ ${#_kw} -lt 8 ]] && continue
            # Skip generic words that appear in almost any test output
            printf '%s' "$_kw" | grep -qiE "^(${_st_stopwords})$" 2>/dev/null && continue
            if printf '%s\n' "$_fail_excerpt" | grep -qiF "$_kw" 2>/dev/null; then
                _test_is_known_flaky="true"
                _matched_flaky_pattern="$_kw"
                break
            fi
        done < <(printf '%s\n' "$_ruflo_flakiness_ctx" | tr ' \t' '\n' | grep -E '^[a-zA-Z0-9_.-]{8,}$' | sort -u | head -30)
        if [[ "$_test_is_known_flaky" == "true" ]]; then
            info "Known flaky pattern matched: '${_matched_flaky_pattern}' — retrying test once"
            local _retry_log="${ARTIFACTS_DIR}/test-results-retry.log"
            local _retry_exit=0
            bash -c "$test_cmd" > "$_retry_log" 2>&1 || _retry_exit=$?
            if [[ "$_retry_exit" -eq 0 ]]; then
                # Validate that retry passed the SAME tests (not a different subset
                # due to environment changes). Compare test counts from both runs.
                local _orig_test_count _retry_test_count
                _orig_test_count=$(grep -cE 'PASS|FAIL|✓|✗|ok [0-9]' "$test_log" 2>/dev/null || true)
                _orig_test_count=${_orig_test_count:-0}
                _retry_test_count=$(grep -cE 'PASS|FAIL|✓|✗|ok [0-9]' "$_retry_log" 2>/dev/null || true)
                _retry_test_count=${_retry_test_count:-0}
                # If retry ran significantly fewer tests (>50% drop), likely an
                # environment change (e.g., dependency installed, config altered)
                # rather than a genuine flaky recovery.
                local _count_valid="true"
                if [[ "$_orig_test_count" -gt 2 && "$_retry_test_count" -gt 0 ]]; then
                    local _half=$(( _orig_test_count / 2 ))
                    if [[ "$_retry_test_count" -lt "$_half" ]]; then
                        _count_valid="false"
                    fi
                fi
                if [[ "$_count_valid" == "true" ]]; then
                    success "Retry succeeded — known flaky test recovered on second attempt"
                    cp "$_retry_log" "$test_log"
                    test_exit=0
                    emit_event "test.flaky_recovered" "pattern=${_matched_flaky_pattern}"
                else
                    warn "Retry passed but ran fewer tests (${_retry_test_count} vs ${_orig_test_count}) — environment may have changed; not marking as flaky recovery"
                fi
            else
                warn "Retry also failed — test consistently failing (matched flaky pattern: '${_matched_flaky_pattern}')"
            fi
        fi
    fi

    # Persist exit code for downstream consumers (avoids grep-based inference)
    local _st_tmp
    _st_tmp=$(mktemp "${ARTIFACTS_DIR}/test-results.status.tmp.XXXXXX")
    if ! ( jq -nc \
        --argjson exit_code "$test_exit" \
        --arg cmd "$test_cmd" \
        --arg finished "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo '')" \
        '{exit_code: $exit_code, passed: ($exit_code == 0), cmd: $cmd, finished_at: $finished}' \
        > "$_st_tmp" && mv "$_st_tmp" "${ARTIFACTS_DIR}/test-results.status.json" ); then
      rm -f "$_st_tmp"
      warn "Failed to write test-results.status.json — downstream consumers will fall back to log parsing"
    fi

    # Extracts per-suite failure summaries from a test log.
    # Looks for suite headers (sw-*-test.sh lines) and failure markers (✗, ●, FAIL).
    _summarize_test_failures() {
        local test_log="$1"
        local max_lines="${2:-40}"
        [[ ! -f "$test_log" ]] && return 0
        awk '
            /sw-[a-z]+-test\.sh/ { suite = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", suite) }
            /^[[:space:]]*(FAIL|✗|●|×)[[:space:]]/ && suite != "" {
                print "  • " suite " — " $0
            }
            /[0-9]+ of [0-9]+ tests? failed/ && suite != "" {
                print "  " suite ": " $0
            }
        ' "$test_log" 2>/dev/null | head -"$max_lines"
    }

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"
    else
        error "Tests failed (exit code: $test_exit)"
        # Extract most relevant error section (assertion failures, stack traces)
        local relevant_output=""
        relevant_output=$(grep -A5 -E 'FAIL|AssertionError|Expected.*but.*got|Error:|panic:|assert' "$test_log" 2>/dev/null | tail -40 | strip_ansi || true)
        if [[ -z "$relevant_output" ]]; then
            relevant_output=$(tail -40 "$test_log" | strip_ansi)
        fi
        echo "$relevant_output"

        # Post failure to GitHub with actionable summary (not full log dump)
        if [[ -n "$ISSUE_NUMBER" ]]; then
            local log_lines
            log_lines=$(wc -l < "$test_log" 2>/dev/null || echo 0)
            log_lines="${log_lines:-0}"

            # Compute dedup hash from sorted failure names to detect identical
            # consecutive GitHub comments. Uses its own state file (NOT the one
            # compound_quality uses for cycle short-circuit, which lives at
            # last-failure-set.sha — shared writes would cross-contaminate the
            # cycle dedup logic). Gated on positive failure count: SHA-1 of empty
            # stdin is a constant, which would falsely match unrelated infra failures.
            local _fail_hash="" _prev_hash="" _stage_test_count
            _stage_test_count=$(grep -cE '^[[:space:]]*(FAIL|✗|●|×)[[:space:]]' "$test_log" 2>/dev/null) || _stage_test_count=0
            _stage_test_count="${_stage_test_count:-0}"
            if [[ "$_stage_test_count" -gt 0 ]]; then
                _fail_hash=$(grep -E '^[[:space:]]*(FAIL|✗|●|×)[[:space:]]' "$test_log" 2>/dev/null \
                    | sort | _compute_sha1 || echo "")
            fi
            if [[ -n "${ARTIFACTS_DIR:-}" && -f "${ARTIFACTS_DIR}/stage-test-last-comment.sha" ]]; then
                _prev_hash=$(cat "${ARTIFACTS_DIR}/stage-test-last-comment.sha" 2>/dev/null | tr -d '[:space:]' || true)
            fi

            local _gh_body
            if [[ -n "$_fail_hash" && "$_fail_hash" == "$_prev_hash" && "$_fail_hash" != no-hasher-* ]]; then
                # Same failures as previous cycle — abbreviated notice
                _gh_body="↺ **Same test failures as previous cycle** (exit code: $test_exit, ${log_lines} lines)

No new failures introduced. See previous comment for details."
            else
                # New or changed failures — show actionable summary
                local _failure_summary
                _failure_summary=$(_summarize_test_failures "$test_log" 30)
                if [[ -z "$_failure_summary" ]]; then
                    # Fallback: last 20 lines of relevant output
                    _failure_summary=$(echo "$relevant_output" | tail -20)
                fi
                _gh_body="❌ **Tests failed** (exit code: $test_exit, ${log_lines} lines)

\`\`\`
${_failure_summary}
\`\`\`"
            fi

            # Save current hash for next stage_test comment dedup (separate from compound_quality)
            if [[ -n "${ARTIFACTS_DIR:-}" && -n "$_fail_hash" ]]; then
                mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
                echo "$_fail_hash" > "${ARTIFACTS_DIR}/stage-test-last-comment.sha" 2>/dev/null || true
            fi

            gh_comment_issue "$ISSUE_NUMBER" "$_gh_body"
        fi
        # Store failed test result in ruflo for flakiness tracking
        if declare -f ruflo_store >/dev/null 2>&1 && \
           declare -f ruflo_available >/dev/null 2>&1 && \
           [[ -n "$_st_ruflo_ns" ]] && \
           ruflo_available; then
            local _fail_names
            _fail_names=$(grep -E '(FAIL|✗|●)[[:space:]]+' "$test_log" 2>/dev/null | head -5 | strip_ansi | tr '\n' ';' | sed 's/;$//' || true)
            [[ -z "$_fail_names" ]] && _fail_names=$(grep -E 'Error:|panic:' "$test_log" 2>/dev/null | head -3 | strip_ansi | tr '\n' ';' | sed 's/;$//' || true)
            local _st_fail_tags="test,stage_test,failed"
            [[ "$_test_is_known_flaky" == "true" ]] && _st_fail_tags="${_st_fail_tags},known_flaky"
            ruflo_store "$_st_result_key" \
                "Tests FAILED (exit $test_exit). Failures: ${_fail_names:-unknown}. Cmd: ${test_cmd}. Time: ${_st_run_uid}." \
                "$_st_ruflo_ns" \
                "$_st_fail_tags" 2>/dev/null || true
        fi
        return 1
    fi

    # Coverage check — only enforce when coverage data is actually detected
    local coverage=""
    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null; then
        coverage=$(parse_coverage_from_output "$test_log")
        if [[ -z "$coverage" ]]; then
            # No coverage data found — skip enforcement (project may not have coverage tooling)
            info "No coverage data detected — skipping coverage check (min: ${coverage_min}%)"
        elif awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
            warn "Coverage ${coverage}% below minimum ${coverage_min}%"
            return 1
        else
            info "Coverage: ${coverage}% (min: ${coverage_min}%)"
        fi
    fi

    # Emit test.completed with coverage for adaptive learning
    if [[ -n "$coverage" ]]; then
        emit_event "test.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=test" \
            "coverage=$coverage"
    fi

    # Post test results to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local test_summary
        test_summary=$(tail -10 "$test_log" | strip_ansi)
        local cov_line=""
        [[ -n "$coverage" ]] && cov_line="
**Coverage:** ${coverage}%"
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Tests passed**${cov_line}
<details>
<summary>Test output</summary>

\`\`\`
${test_summary}
\`\`\`
</details>"
    fi

    # Write coverage summary for pre-deploy gate
    local _cov_pct=0
    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]]; then
        _cov_pct=$(grep -oE '[0-9]+%' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -1 | tr -d '%' || true)
        _cov_pct="${_cov_pct:-0}"
    fi
    local _cov_tmp
    _cov_tmp=$(mktemp "${ARTIFACTS_DIR}/test-coverage.json.tmp.XXXXXX")
    printf '{"coverage_pct":%d}' "${_cov_pct:-0}" > "$_cov_tmp" && mv "$_cov_tmp" "$ARTIFACTS_DIR/test-coverage.json" || rm -f "$_cov_tmp"

    # Store test results in ruflo for cross-stage context and flakiness tracking
    if declare -f ruflo_store >/dev/null 2>&1 && \
       declare -f ruflo_available >/dev/null 2>&1 && \
       [[ -n "$_st_ruflo_ns" ]] && \
       ruflo_available; then
        local _pass_test_names
        _pass_test_names=$(grep -E '(PASS|✓)[[:space:]]+' "$test_log" 2>/dev/null | head -5 | strip_ansi | tr '\n' ';' | sed 's/;$//' || true)
        [[ -z "$_pass_test_names" ]] && _pass_test_names=$(grep -cE 'PASS|✓|ok [0-9]' "$test_log" 2>/dev/null | tr -d '\n' || true)
        local _st_pass_tags="test,stage_test,passed"
        [[ "$_test_is_known_flaky" == "true" ]] && _st_pass_tags="${_st_pass_tags},flaky_recovered"
        ruflo_store "$_st_result_key" \
            "Tests PASSED. Tests: ${_pass_test_names:-unknown}. Cmd: ${test_cmd}. Coverage: ${_cov_pct:-0}%. Time: ${_st_run_uid}." \
            "$_st_ruflo_ns" \
            "$_st_pass_tags" 2>/dev/null || true
    fi

    log_stage "test" "Tests passed${coverage:+ (coverage: ${coverage}%)}"
}

