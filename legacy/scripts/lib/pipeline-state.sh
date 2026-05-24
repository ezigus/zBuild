# pipeline-state.sh — Pipeline state management (for sw-pipeline.sh)
# Source from sw-pipeline.sh. Requires SCRIPT_DIR, ARTIFACTS_DIR, and helpers.
[[ -n "${_PIPELINE_STATE_LOADED:-}" ]] && return 0
_PIPELINE_STATE_LOADED=1

# Source goal sanitization helper (strips synthesized sections from goals)
# shellcheck source=goal-sanitize.sh
[[ -f "$(dirname "${BASH_SOURCE[0]}")/goal-sanitize.sh" ]] && source "$(dirname "${BASH_SOURCE[0]}")/goal-sanitize.sh"

# Source scope_label into this process (also sourced by sw-loop.sh for cross-process label availability)
_SCOPE_LABEL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scope-label.sh"
[[ -f "$_SCOPE_LABEL_SH" ]] && source "$_SCOPE_LABEL_SH"
unset _SCOPE_LABEL_SH

# Ensure _trim is available (normally provided by helpers.sh, but this file
# may be sourced in test harnesses that stub helpers instead of sourcing them).
if ! type _trim >/dev/null 2>&1; then
    _trim() {
        local s="${1:-}"
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        printf '%s' "$s"
    }
fi

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
STAGE_STATUSES="${STAGE_STATUSES:-}"
STAGE_TIMINGS="${STAGE_TIMINGS:-}"
LOG_ENTRIES="${LOG_ENTRIES:-}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
GOAL="${GOAL:-}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline}"
PIPELINE_STATUS="${PIPELINE_STATUS:-pending}"
# Epoch set once at pipeline start; persisted across resumes (unlike PIPELINE_START_EPOCH,
# which is reset on resume to measure elapsed-from-resume time).  Used to detect stale
# artifacts from prior runs.  0 = unset / unknown (freshness checks pass through).
PIPELINE_RUN_EPOCH="${PIPELINE_RUN_EPOCH:-0}"
OUTER_STAGE="${OUTER_STAGE:-}"   # set when inside a nested execution context (e.g. compound rebuild)
OUTER_STAGE_START_COMMIT="${OUTER_STAGE_START_COMMIT:-}"  # HEAD at compound_quality entry (for diff-base accuracy)
INNER_STAGE="${INNER_STAGE:-}"   # the nested stage being executed (build/test/review)
COMPOUND_QUALITY_CYCLE="${COMPOUND_QUALITY_CYCLE:-1}"  # current compound_quality cycle number (1-based)
SELF_HEAL_COUNT="${SELF_HEAL_COUNT:-0}"                # build iterations completed (0 = first run)

save_artifact() {
    local name="$1" content="$2"
    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
    echo "$content" > "$ARTIFACTS_DIR/$name"
}

get_stage_status() {
    local stage_id="$1"
    echo "$STAGE_STATUSES" | grep "^${stage_id}:" | cut -d: -f2 | tail -1 || true
}

set_outer_stage() { OUTER_STAGE="$1"; INNER_STAGE=""; write_state; }
clear_outer_stage() { OUTER_STAGE=""; INNER_STAGE=""; write_state; }

# scope_label is defined in scope-label.sh (sourced above).

set_stage_status() {
    local stage_id="$1" status="$2"
    # When inside a nested execution context (OUTER_STAGE is set), suppress STAGE_STATUSES
    # mutations for any stage other than the outer stage itself. Inner-cycle transitions
    # (build/test/review inside compound_quality) are recorded in log entries and the DB
    # but must not overwrite the outer stage's structured status table.
    # Example: mark_stage_failed "build" inside compound_quality must NOT flip
    # stages.build: complete → failed; that would be misleading in cancellation snapshots.
    #
    # Note: log_stage and DB record calls downstream of this gate (inside
    # mark_stage_complete/mark_stage_failed) still fire. STAGE_STATUSES is the canonical
    # structured record; LOG_ENTRIES (## Log) is a chronological audit trail that
    # legitimately contains inner-cycle entries, and the SQLite pipeline_stages table
    # is a separate sink with its own semantics.
    if [[ -n "${OUTER_STAGE:-}" && "$stage_id" != "$OUTER_STAGE" ]]; then
        return 0
    fi
    STAGE_STATUSES=$(echo "$STAGE_STATUSES" | grep -v "^${stage_id}:" || true)
    STAGE_STATUSES="${STAGE_STATUSES}
${stage_id}:${status}"
}

# Per-stage timing
record_stage_start() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_start:$(now_epoch)"
}

record_stage_end() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_end:$(now_epoch)"
}

get_stage_timing() {
    local stage_id="$1"
    local start_e end_e
    start_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_start:" | cut -d: -f2 | tail -1 || true)
    end_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_end:" | cut -d: -f2 | tail -1 || true)
    if [[ -n "$start_e" && -n "$end_e" ]]; then
        format_duration $(( end_e - start_e ))
    elif [[ -n "$start_e" ]]; then
        format_duration $(( $(now_epoch) - start_e ))
    else
        echo ""
    fi
}

# Raw seconds for a stage (for memory baseline updates)
get_stage_timing_seconds() {
    local stage_id="$1"
    local start_e end_e
    start_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_start:" | cut -d: -f2 | tail -1 || true)
    end_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_end:" | cut -d: -f2 | tail -1 || true)
    if [[ -n "$start_e" && -n "$end_e" ]]; then
        echo $(( end_e - start_e ))
    elif [[ -n "$start_e" ]]; then
        echo $(( $(now_epoch) - start_e ))
    else
        echo "0"
    fi
}

# Name of the slowest completed stage (for pipeline.completed event)
get_slowest_stage() {
    local slowest="" max_sec=0
    local stage_ids
    stage_ids=$(echo "$STAGE_TIMINGS" | grep "_start:" | sed 's/_start:.*//' | sort -u)
    for sid in $stage_ids; do
        [[ -z "$sid" ]] && continue
        local sec
        sec=$(get_stage_timing_seconds "$sid")
        if [[ -n "$sec" && "$sec" =~ ^[0-9]+$ && "$sec" -gt "$max_sec" ]]; then
            max_sec="$sec"
            slowest="$sid"
        fi
    done
    echo "${slowest:-}"
}

get_stage_description() {
    local stage_id="$1"

    # Try to generate dynamic description from pipeline config
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        local stage_cfg
        stage_cfg=$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id) | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null || echo "{}")
        case "$stage_id" in
            test)
                local cfg_test_cmd cfg_cov_min
                cfg_test_cmd=$(echo "$stage_cfg" | jq -r '.test_cmd // empty' 2>/dev/null || true)
                cfg_cov_min=$(echo "$stage_cfg" | jq -r '.coverage_min // empty' 2>/dev/null || true)
                if [[ -n "$cfg_test_cmd" ]]; then
                    echo "Running ${cfg_test_cmd}${cfg_cov_min:+ with ${cfg_cov_min}% coverage gate}"
                    return
                fi
                ;;
            build)
                local cfg_max_iter cfg_model
                cfg_max_iter=$(echo "$stage_cfg" | jq -r '.max_iterations // empty' 2>/dev/null || true)
                cfg_model=$(jq -r '.defaults.model // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
                if [[ -n "$cfg_max_iter" ]]; then
                    echo "Building with ${cfg_max_iter} max iterations${cfg_model:+ using ${cfg_model}}"
                    return
                fi
                ;;
            monitor)
                local cfg_dur cfg_thresh
                cfg_dur=$(echo "$stage_cfg" | jq -r '.duration_minutes // empty' 2>/dev/null || true)
                cfg_thresh=$(echo "$stage_cfg" | jq -r '.error_threshold // empty' 2>/dev/null || true)
                if [[ -n "$cfg_dur" ]]; then
                    echo "Monitoring for ${cfg_dur}m${cfg_thresh:+ (threshold: ${cfg_thresh} errors)}"
                    return
                fi
                ;;
        esac
    fi

    # Static fallback descriptions
    case "$stage_id" in
        intake)           echo "Extracting requirements and auto-detecting project setup" ;;
        plan)             echo "Creating implementation plan with architecture decisions" ;;
        design)           echo "Designing interfaces, data models, and API contracts" ;;
        build)            echo "Writing production code with self-healing iteration" ;;
        test)             echo "Running test suite and validating coverage" ;;
        review)           echo "Code quality, security audit, performance review" ;;
        compound_quality) echo "Adversarial testing, E2E validation, DoD checklist" ;;
        resync)           echo "Syncing branch with base before PR" ;;
        pr)               echo "Creating pull request with CI integration" ;;
        merge)            echo "Merging PR with branch cleanup" ;;
        deploy)           echo "Deploying to staging/production" ;;
        validate)         echo "Smoke tests and health checks post-deploy" ;;
        monitor)          echo "Production monitoring with auto-rollback" ;;
        *)                echo "" ;;
    esac
}

# Build inline stage progress string (e.g. "intake:complete plan:running test:pending")
build_stage_progress() {
    local progress=""
    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null) || return 0
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        [[ "$enabled" != "true" ]] && continue
        local sstatus
        sstatus=$(get_stage_status "$id")
        sstatus="${sstatus:-pending}"
        if [[ -n "$progress" ]]; then
            progress="${progress} ${id}:${sstatus}"
        else
            progress="${id}:${sstatus}"
        fi
    done 3<<< "$stages"
    echo "$progress"
}

update_status() {
    local status="$1" stage="$2"
    PIPELINE_STATUS="$status"
    if [[ -n "${OUTER_STAGE:-}" ]]; then
        # Inside a nested execution context — redirect stage write to inner_stage
        # so current_stage: remains truthful (= the outer stage, e.g. compound_quality).
        INNER_STAGE="$stage"
    else
        CURRENT_STAGE="$stage"
        INNER_STAGE=""
    fi
    UPDATED_AT="$(now_iso)"
    write_state
}

write_pipeline_status_json() {
    local state_file=".claude/pipeline-status.json"
    local tmp_file="${state_file}.tmp.$$"

    # Build completed_stages JSON array from STAGE_STATUSES
    local completed_arr="[]"
    local stage line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        stage="${line%%:*}"
        local st="${line#*:}"
        if [[ "$st" == "complete" && -n "$stage" ]]; then
            local _new_arr
            if _new_arr=$(printf '%s' "$completed_arr" | jq --arg s "$stage" '. + [$s]' 2>/dev/null); then
                completed_arr="$_new_arr"
            else
                completed_arr="[]"
            fi
        fi
    done <<EOF
$STAGE_STATUSES
EOF

    # Get current stage (last started, not yet complete)
    local current_stage=""
    current_stage=$(echo "$STAGE_STATUSES" | grep ':in_progress$' | tail -1 | cut -d: -f1 || true)
    [[ -z "$current_stage" ]] && current_stage=$(echo "$STAGE_STATUSES" | grep ':complete$' | tail -1 | cut -d: -f1 || true)

    mkdir -p ".claude" 2>/dev/null || true
    jq -n \
        --arg run_id "${GITHUB_RUN_ID:-local}" \
        --arg branch "shipwright/issue-${ISSUE_NUMBER:-0}" \
        --arg stage "${current_stage:-}" \
        --argjson iteration "${CURRENT_ITERATION:-0}" \
        --argjson retry_count "${RETRY_COUNT:-0}" \
        --arg last_heartbeat "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg exit_reason "" \
        --arg error_category "" \
        --argjson completed_stages "${completed_arr:-[]}" \
        '{run_id:$run_id,branch:$branch,stage:$stage,iteration:$iteration,retry_count:$retry_count,last_heartbeat:$last_heartbeat,exit_reason:$exit_reason,error_category:$error_category,completed_stages:$completed_stages}' \
        > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$state_file" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; return 1; }
}

mark_stage_complete() {
    local stage_id="$1"
    record_stage_effectiveness "$stage_id" "complete"

    # CI branch invariant: HEAD must be on WORKSPACE_BRANCH.
    # If drift is detected, attempt to recover via merge, fail loudly only if unmergeable.
    if [[ "${CI_MODE:-false}" == "true" && -n "${WORKSPACE_BRANCH:-}" ]]; then
        local _head
        _head=$(git symbolic-ref --short HEAD 2>/dev/null || echo "<detached>")
        if [[ "$_head" != "$WORKSPACE_BRANCH" ]]; then
            warn "Branch drift: HEAD=${_head}, expected=${WORKSPACE_BRANCH}. Attempting auto-recover for stage '${stage_id}'."
            emit_event "pipeline.branch_drift_detected" \
                "head=${_head} expected=${WORKSPACE_BRANCH} stage=${stage_id}" 2>/dev/null || true
            local _drift_sha
            _drift_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [[ -n "$_drift_sha" ]] \
               && git checkout "$WORKSPACE_BRANCH" 2>/dev/null \
               && git merge --no-edit --no-ff "$_drift_sha" 2>/dev/null; then
                info "Branch drift recovered: merged ${_drift_sha:0:7} from ${_head} into ${WORKSPACE_BRANCH}"
                emit_event "pipeline.branch_drift_recovered" "merged=${_drift_sha:0:7}" 2>/dev/null || true
            else
                git merge --abort 2>/dev/null || true
                error "Branch drift unrecoverable: could not merge drift from ${_head} into ${WORKSPACE_BRANCH}. Stage '${stage_id}' not marked complete."
                return 1
            fi
        fi
    fi

    record_stage_end "$stage_id"
    set_stage_status "$stage_id" "complete"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "complete (${timing})"
    write_state

    # Record stage completion in SQLite pipeline_stages table
    if type record_stage >/dev/null 2>&1; then
        local _stage_secs
        _stage_secs=$(get_stage_timing_seconds "$stage_id")
        record_stage "${SHIPWRIGHT_PIPELINE_ID:-}" "$stage_id" "complete" "${_stage_secs:-0}" "" 2>/dev/null || true
    fi

    # Record skill outcome for learning system
    if type skill_memory_record >/dev/null 2>&1; then
        local _used_skills
        _used_skills=$(skill_get_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
        [[ -n "$_used_skills" ]] && skill_memory_record "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" "$_used_skills" "success" "1" 2>/dev/null || true
    fi

    # Update memory baselines and predictive baselines for stage durations
    if [[ "$stage_id" == "test" || "$stage_id" == "build" ]]; then
        local secs
        secs=$(get_stage_timing_seconds "$stage_id")
        if [[ -n "$secs" && "$secs" != "0" ]]; then
            [[ -x "$SCRIPT_DIR/sw-memory.sh" ]] && bash "$SCRIPT_DIR/sw-memory.sh" metric "${stage_id}_duration_s" "$secs" 2>/dev/null || true
            if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
                local anomaly_sev
                anomaly_sev=$(bash "$SCRIPT_DIR/sw-predictive.sh" anomaly "$stage_id" "duration_s" "$secs" 2>/dev/null || echo "normal")
                [[ "$anomaly_sev" == "critical" || "$anomaly_sev" == "warning" ]] && emit_event "pipeline.anomaly" "stage=$stage_id" "metric=duration_s" "value=$secs" "severity=$anomaly_sev" 2>/dev/null || true
                bash "$SCRIPT_DIR/sw-predictive.sh" baseline "$stage_id" "duration_s" "$secs" 2>/dev/null || true
            fi
        fi
    fi

    # Update GitHub progress comment
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"

        # Notify tracker (Linear/Jira) of stage completion
        local stage_desc
        stage_desc=$(get_stage_description "$stage_id")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_complete" "$ISSUE_NUMBER" \
            "${stage_id}|${timing}|${stage_desc}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "complete" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
        gh_checks_stage_update "$stage_id" "completed" "success" "Stage $stage_id: ${timing}" 2>/dev/null || true
    fi

    # Persist artifacts to feature branch at every stage boundary.
    # persist_artifacts now always force-adds pipeline-state.md (gitignored);
    # stage-specific artifact files are additive on top.
    case "$stage_id" in
        plan)   persist_artifacts "plan"   "plan.md" "dod.md" "context-bundle.md" ;;
        design) persist_artifacts "design" "design.md" ;;
        *)      persist_artifacts "$stage_id" ;;
    esac

    # Automatic checkpoint at every stage boundary (for crash recovery)
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local _cp_sha _cp_files
        _cp_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        _cp_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | head -20 | tr '\n' ',' || true)
        bash "$SCRIPT_DIR/sw-checkpoint.sh" save \
            --stage "$stage_id" \
            --iteration "${SELF_HEAL_COUNT:-0}" \
            --git-sha "$_cp_sha" \
            --files-modified "${_cp_files:-}" \
            --tests-passing "${TEST_PASSED:-false}" 2>/dev/null || true
    fi

    # Durable WAL: publish stage completion event
    if type publish_event >/dev/null 2>&1; then
        publish_event "stage.complete" "{\"stage\":\"${stage_id}\",\"issue\":\"${ISSUE_NUMBER:-0}\",\"timing\":\"${timing}\"}" 2>/dev/null || true
    fi

    # Durable checkpoint: save to DB for pipeline resume
    if type db_save_checkpoint >/dev/null 2>&1; then
        local checkpoint_data
        checkpoint_data=$(jq -nc --arg stage "$stage_id" --arg status "${PIPELINE_STATUS:-running}" \
            --arg issue "${ISSUE_NUMBER:-}" --arg goal "${GOAL:-}" --arg template "${PIPELINE_TEMPLATE:-}" \
            '{stage: $stage, status: $status, issue: $issue, goal: $goal, template: $template, ts: "'"$(now_iso)"'"}')
        db_save_checkpoint "pipeline-${SHIPWRIGHT_PIPELINE_ID:-$$}" "$checkpoint_data" 2>/dev/null || true
    fi

    # Write structured JSON status file for meta-workflows
    if ! write_pipeline_status_json; then
        warn "Failed to write pipeline-status.json — CI resume may restart from stage 1"
        emit_event "pipeline.status_json_failed" "stage=${stage_id}" 2>/dev/null || true
    fi
}

persist_artifacts() {
    # Commit pipeline artifacts + state files to the feature branch mid-pipeline.
    # Always force-adds pipeline-state.md (gitignored) for resume reliability.
    # Snapshots progress.md from loop-logs so mid-stage resume has an iteration cursor.
    # Opportunistically pushes after commit using flock (.claude/.push.lock), shared
    # with _start_state_heartbeat to prevent concurrent git-push races. Push is
    # non-fatal; GHA post-steps and heartbeat are additional safety nets.
    # GHA always() does NOT fire on hard timeout-minutes job kill, so we can't rely
    # on the post-step alone — hence the opportunistic push here.
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0

    local stage="${1:-unknown}"
    shift
    local files=("$@")

    # Migrate committed last_optimization blocks to sidecar on WIP branches.
    # Note: persist_artifacts only runs when CI_MODE=true; daemon startup handles local runs.
    declare -f _migrate_last_optimization >/dev/null 2>&1 && _migrate_last_optimization || true

    # Copy root state files into the issue-scoped snapshot dir and stage from there.
    # Never stage the root paths directly — they leak onto main on merge (tracked via
    # git add -f bypasses .gitignore and survives WIP→main merges).
    local _pa_snap_dir="${ARTIFACTS_DIR}/issue-${ISSUE_NUMBER}"
    mkdir -p "$_pa_snap_dir" 2>/dev/null || true
    cp ".claude/pipeline-state.md"    "${_pa_snap_dir}/pipeline-state.md"    2>/dev/null || true
    cp ".claude/pipeline-status.json" "${_pa_snap_dir}/pipeline-status.json" 2>/dev/null || true
    git add -f "${_pa_snap_dir}/pipeline-state.md" \
               "${_pa_snap_dir}/pipeline-status.json" 2>/dev/null || true

    # Snapshot gitignored progress.md into artifacts dir so it travels with state
    if [[ -n "${ARTIFACTS_DIR:-}" && -f ".claude/loop-logs/progress.md" ]]; then
        cp ".claude/loop-logs/progress.md" "${ARTIFACTS_DIR}/progress.md" 2>/dev/null || true
        git add -f "${ARTIFACTS_DIR}/progress.md" 2>/dev/null || true
    fi

    # Collect stage-specific artifact files from ARTIFACTS_DIR
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        local to_add=()
        for f in "${files[@]}"; do
            local path="${ARTIFACTS_DIR}/${f}"
            if [[ -f "$path" && -s "$path" ]]; then
                to_add+=("$path")
            fi
        done
        if [[ ${#to_add[@]} -gt 0 ]]; then
            git add "${to_add[@]}" 2>/dev/null || true
        fi
    fi

    # Nothing staged — nothing to do
    if git diff --cached --quiet 2>/dev/null; then
        return 0
    fi

    local commit_status="commit_failed"
    local _commit_err
    if _commit_err=$(git commit -m "chore: persist ${stage} artifacts for #${ISSUE_NUMBER} [skip ci]" \
            --no-verify 2>&1); then
        commit_status="committed"
    else
        warn "persist_artifacts($stage): commit failed: ${_commit_err:-<no output>}"
    fi

    case "$commit_status" in
        committed)
            emit_event "artifacts.persisted" \
                "issue=${ISSUE_NUMBER}" "stage=$stage" 2>/dev/null || true
            # Opportunistic push: GHA always() doesn't fire on hard job timeout.
            # Non-fatal; post-step + heartbeat are additional safety nets.
            # Uses flock (.claude/.push.lock) shared with _start_state_heartbeat
            # to prevent concurrent git-push races.
            if [[ -n "${WORKSPACE_BRANCH:-}" ]]; then
                local _pa_push_ok=true
                if type _assert_push_target_matches_active_issue >/dev/null 2>&1; then
                    _assert_push_target_matches_active_issue "$WORKSPACE_BRANCH" || _pa_push_ok=false
                fi
                if [[ "$_pa_push_ok" == "true" ]]; then
                    local _lock_file=".claude/.push.lock"
                    if command -v flock >/dev/null 2>&1; then
                        (
                            flock -n 9 2>/dev/null || exit 0
                            if _timeout 30 git push --force-with-lease origin \
                                "HEAD:refs/heads/${WORKSPACE_BRANCH}" 2>/dev/null; then
                                info "persist_artifacts: pushed state for ${stage}"
                            else
                                warn "persist_artifacts: push failed for ${stage} (post-step will retry)"
                            fi
                        ) 9>"$_lock_file"
                    else
                        if _timeout 30 git push --force-with-lease origin \
                            "HEAD:refs/heads/${WORKSPACE_BRANCH}" 2>/dev/null; then
                            info "persist_artifacts: pushed state for ${stage}"
                        else
                            warn "persist_artifacts: push failed for ${stage} (post-step will retry)"
                        fi
                    fi
                else
                    warn "persist_artifacts($stage): push guard blocked push to $WORKSPACE_BRANCH"
                fi
            fi
            ;;
        commit_failed)
            emit_event "artifacts.persist_failed" "issue=${ISSUE_NUMBER}" "stage=$stage" 2>/dev/null || true
            ;;
    esac

    return 0
}

verify_stage_artifacts() {
    # Check that required artifacts exist and are non-empty for a given stage.
    # Returns 0 if all artifacts are present, 1 if any are missing.
    local stage_id="$1"
    [[ -z "${ARTIFACTS_DIR:-}" ]] && return 0

    local required=()
    case "$stage_id" in
        plan)   required=("plan.md") ;;
        design) required=("design.md" "plan.md") ;;
        *)      return 0 ;;  # No artifact check needed
    esac

    local missing=0
    for f in "${required[@]}"; do
        local path="${ARTIFACTS_DIR}/${f}"
        if [[ ! -f "$path" || ! -s "$path" ]]; then
            warn "verify_stage_artifacts($stage_id): missing or empty: $f"
            missing=1
        fi
    done

    return "$missing"
}

# Self-aware pipeline: record stage effectiveness for meta-cognition
STAGE_EFFECTIVENESS_FILE="${HOME}/.shipwright/stage-effectiveness.jsonl"
record_stage_effectiveness() {
    local stage_id="$1" outcome="${2:-failed}"
    mkdir -p "${HOME}/.shipwright"
    echo "{\"stage\":\"$stage_id\",\"outcome\":\"$outcome\",\"ts\":\"$(now_iso)\"}" >> "${STAGE_EFFECTIVENESS_FILE}"
    # Keep last 100 entries
    tail -100 "${STAGE_EFFECTIVENESS_FILE}" > "${STAGE_EFFECTIVENESS_FILE}.tmp" 2>/dev/null && mv "${STAGE_EFFECTIVENESS_FILE}.tmp" "${STAGE_EFFECTIVENESS_FILE}" 2>/dev/null || true
}
get_stage_self_awareness_hint() {
    local stage_id="$1"
    [[ ! -f "$STAGE_EFFECTIVENESS_FILE" ]] && return 0
    local recent
    recent=$(grep "\"stage\":\"$stage_id\"" "$STAGE_EFFECTIVENESS_FILE" 2>/dev/null | tail -10 || true)
    [[ -z "$recent" ]] && return 0
    local failures=0 total=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        echo "$line" | grep -q '"outcome":"failed"' && failures=$((failures + 1)) || true
    done <<< "$recent"
    if [[ "$total" -ge 3 ]] && [[ $((failures * 100 / total)) -ge 50 ]]; then
        case "$stage_id" in
            plan)  echo "Recent plan stage failures: consider adding more context or breaking the goal into smaller steps." ;;
            build) echo "Recent build stage failures: consider adding test expectations or simplifying the change." ;;
            *)     echo "Recent $stage_id failures: review past logs and adjust approach." ;;
        esac
    fi
}

# Resolves the log file path for a stage, handling both underscore and hyphen forms.
# stage_id may use underscores (compound_quality) but log files may use hyphens (compound-quality.log).
_resolve_stage_log_path() {
    local stage_id="$1"
    local underscore_form="${ARTIFACTS_DIR}/${stage_id}.log"
    local hyphen_form="${ARTIFACTS_DIR}/${stage_id//_/-}.log"
    if [[ -f "$underscore_form" ]]; then
        echo "$underscore_form"
    elif [[ -f "$hyphen_form" ]]; then
        echo "$hyphen_form"
    else
        return 1
    fi
}

mark_stage_failed() {
    local stage_id="$1"
    record_stage_end "$stage_id"
    record_stage_effectiveness "$stage_id" "failed"
    set_stage_status "$stage_id" "failed"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "failed (${timing})"
    write_state

    # Record stage failure in SQLite pipeline_stages table
    if type record_stage >/dev/null 2>&1; then
        local _stage_secs
        _stage_secs=$(get_stage_timing_seconds "$stage_id")
        record_stage "${SHIPWRIGHT_PIPELINE_ID:-}" "$stage_id" "failed" "${_stage_secs:-0}" "" 2>/dev/null || true
    fi

    # Record skill failure for learning system
    if type skill_memory_record >/dev/null 2>&1; then
        local _used_skills
        _used_skills=$(skill_get_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')
        [[ -n "$_used_skills" ]] && skill_memory_record "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" "$_used_skills" "failure" "1" 2>/dev/null || true
    fi

    # Update GitHub progress + comment failure
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
        # Suppress the definitive failure comment when inside a nested execution context
        # (e.g. compound_quality's inner build/test cycle). The outer stage is still running;
        # a "❌ Pipeline failed at build" comment would be a false alarm.
        if [[ -z "${OUTER_STAGE:-}" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "❌ Pipeline failed at stage **${stage_id}** after ${timing}.

\`\`\`
$( \
    _log_path=$(_resolve_stage_log_path "${stage_id:-unknown}"); \
    if [[ -n "$_log_path" ]]; then \
        tail -5 "$_log_path" 2>/dev/null || echo 'Log file unreadable'; \
    else \
        printf 'Diagnostic: stage %s produced no log at %s/{%s,%s}.log\n' \
            "${stage_id:-unknown}" "${ARTIFACTS_DIR}" \
            "${stage_id:-unknown}" "${stage_id//_/-}"; \
        printf 'Check: ARTIFACTS_DIR=%s, last-stderr.log for process output\n' "${ARTIFACTS_DIR}"; \
    fi \
)
\`\`\`"
        fi

        # Notify tracker (Linear/Jira) of stage failure.
        # `|| _ec_log=""` so set -e doesn't abort mark_stage_failed when no log found.
        local error_context _ec_log
        _ec_log=$(_resolve_stage_log_path "${stage_id:-unknown}") || _ec_log=""
        error_context=$(tail -5 "${_ec_log:-/dev/null}" 2>/dev/null || echo "No log")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_failed" "$ISSUE_NUMBER" \
            "${stage_id}|${error_context}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "failed" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
        local fail_summary _fs_log
        _fs_log=$(_resolve_stage_log_path "${stage_id:-unknown}") || _fs_log=""
        fail_summary=$(tail -3 "${_fs_log:-/dev/null}" 2>/dev/null | head -c 500 || echo "Stage $stage_id failed")
        gh_checks_stage_update "$stage_id" "completed" "failure" "$fail_summary" 2>/dev/null || true
    fi

    # Save checkpoint on failure too (for crash recovery / resume)
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local _cp_sha
        _cp_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        bash "$SCRIPT_DIR/sw-checkpoint.sh" save \
            --stage "$stage_id" \
            --iteration "${SELF_HEAL_COUNT:-0}" \
            --git-sha "$_cp_sha" \
            --tests-passing "false" 2>/dev/null || true
    fi

    # Durable WAL: publish stage failure event
    if type publish_event >/dev/null 2>&1; then
        publish_event "stage.failed" "{\"stage\":\"${stage_id}\",\"issue\":\"${ISSUE_NUMBER:-0}\",\"timing\":\"${timing}\"}" 2>/dev/null || true
    fi
}

log_stage() {
    local stage_id="$1" message="$2"
    local timestamp
    timestamp=$(date +"%H:%M:%S")
    LOG_ENTRIES="${LOG_ENTRIES}
### ${stage_id} (${timestamp})
${message}
"
}

# ─── Artifact Cleanup Helpers ─────────────────────────────────────────────────

# _cleanup_run_artifacts — whitelist-based removal of per-run artifacts.
# Preserves the cumulative audit trail; removes everything else in ARTIFACTS_DIR
# (flat files, dotfiles, and per-run subdirectories like stage-outputs/ and wiki/).
# Uses a case statement for the whitelist so this is Bash 3.2 compatible.
_cleanup_run_artifacts() {
    [[ -z "${ARTIFACTS_DIR:-}" || ! -d "$ARTIFACTS_DIR" ]] && return 0
    local f base

    # Flat files
    for f in "$ARTIFACTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            pipeline-audit.jsonl|pipeline-audit.json|pipeline-audit.md|\
            rollbacks.jsonl|last-issue.txt|error-log.jsonl|composed-pipeline.json)
                continue ;;
        esac
        rm -f "$f"
    done

    # Dotfiles (.plan-failure-sig.txt, .skill-*, model-routing.log written as dot, etc.)
    for f in "$ARTIFACTS_DIR"/.*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        rm -f "$f"
    done

    # Per-run subdirectories
    local d
    for d in "$ARTIFACTS_DIR"/stage-outputs "$ARTIFACTS_DIR"/wiki "$ARTIFACTS_DIR"/checkpoints; do
        [[ -d "$d" ]] && rm -rf "$d"
    done

    return 0
}

# _cleanup_stale_artifacts_on_resume — mtime-based removal of artifacts that
# predate the current pipeline run.  Catches leftovers that survived initialize_state
# (e.g., artifacts from a genuinely different pipeline sharing the same worktree).
# No-op when PIPELINE_RUN_EPOCH is 0/unset (backward compat).
_cleanup_stale_artifacts_on_resume() {
    [[ -z "${ARTIFACTS_DIR:-}" || ! -d "$ARTIFACTS_DIR" ]] && return 0
    local epoch="${PIPELINE_RUN_EPOCH:-0}"
    [[ "$epoch" == "0" || -z "$epoch" ]] && return 0
    type file_mtime >/dev/null 2>&1 || return 0

    local f base mtime
    for f in "$ARTIFACTS_DIR"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            pipeline-audit.jsonl|pipeline-audit.json|pipeline-audit.md|\
            rollbacks.jsonl|last-issue.txt|error-log.jsonl)
                continue ;;
        esac
        mtime=$(file_mtime "$f")
        if [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -lt "$epoch" ]]; then
            rm -f "$f"
        fi
    done

    for f in "$ARTIFACTS_DIR"/.*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        mtime=$(file_mtime "$f")
        if [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -lt "$epoch" ]]; then
            rm -f "$f"
        fi
    done

    # Sweep stale files inside per-run subdirectories (e.g. checkpoints/ left by a
    # different pipeline that previously occupied this worktree).
    local d
    for d in "$ARTIFACTS_DIR"/checkpoints; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*; do
            [[ -f "$f" ]] || continue
            mtime=$(file_mtime "$f")
            if [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -lt "$epoch" ]]; then
                rm -f "$f"
            fi
        done
    done

    return 0
}

initialize_state() {
    PIPELINE_STATUS="running"
    PIPELINE_START_EPOCH="$(now_epoch)"
    PIPELINE_RUN_EPOCH="$PIPELINE_START_EPOCH"
    STARTED_AT="$(now_iso)"
    UPDATED_AT="$(now_iso)"
    STAGE_STATUSES=""
    STAGE_TIMINGS=""
    LOG_ENTRIES=""
    # Remove all per-run artifacts (whitelist-based); preserves cumulative audit trail
    _cleanup_run_artifacts
    # Clear task list so stale tasks from a previous pipeline run are not injected
    [[ -n "${TASKS_FILE:-}" ]] && rm -f "$TASKS_FILE"
    write_state
}

write_state() {
    [[ -z "${STATE_FILE:-}" || -z "${ARTIFACTS_DIR:-}" ]] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

    # Check disk space before write (100MB minimum)
    if ! check_disk_space "$(dirname "$STATE_FILE")" 100; then
        error "Cannot write state: insufficient disk space"
        return 1
    fi
    local stages_yaml=""
    while IFS=: read -r sid sstatus; do
        [[ -z "$sid" ]] && continue
        stages_yaml="${stages_yaml}  ${sid}: ${sstatus}
"
    done <<< "$STAGE_STATUSES"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Stage description and progress for dashboard enrichment
    local cur_stage_desc=""
    if [[ -n "${CURRENT_STAGE:-}" ]]; then
        cur_stage_desc=$(get_stage_description "$CURRENT_STAGE")
    fi
    local stage_progress=""
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        stage_progress=$(build_stage_progress)
    fi

    # Atomic write: build content in tmp file, then mv into place.
    # This prevents partial/corrupt state files when interrupted by signals.
    # Always persist ORIGINAL_GOAL (clean) to both goal: and original_goal: fields.
    # Bootstrap ORIGINAL_GOAL from GOAL on first non-empty write for the --issue flow
    # where intake calls write_state with GOAL set and ORIGINAL_GOAL still empty.
    if [[ -z "${ORIGINAL_GOAL:-}" && -n "${GOAL:-}" ]]; then
        ORIGINAL_GOAL="$GOAL"
    fi
    local tmp_state="${STATE_FILE}.tmp.$$"
    local _orig_goal_esc="${ORIGINAL_GOAL//\\/\\\\}"
    _orig_goal_esc="${_orig_goal_esc//$'\n'/\\n}"
    {
        printf -- '---\n'
        printf 'pipeline: %s\n' "$PIPELINE_NAME"
        printf 'goal: "%s"\n' "$_orig_goal_esc"
        printf 'original_goal: "%s"\n' "$_orig_goal_esc"
        printf 'status: %s\n' "$PIPELINE_STATUS"
        printf 'issue: "%s"\n' "${GITHUB_ISSUE:-}"
        printf 'branch: "%s"\n' "${GIT_BRANCH:-}"
        printf 'template: "%s"\n' "${TASK_TYPE:+$(template_for_type "$TASK_TYPE")}"
        printf 'current_stage: %s\n' "$CURRENT_STAGE"
        printf 'outer_stage: %s\n' "${OUTER_STAGE:-}"
        printf 'outer_stage_start_commit: %s\n' "${OUTER_STAGE_START_COMMIT:-}"
        printf 'inner_stage: %s\n' "${INNER_STAGE:-}"
        printf 'current_stage_description: "%s"\n' "${cur_stage_desc}"
        printf 'stage_progress: "%s"\n' "${stage_progress}"
        printf 'started_at: %s\n' "${STARTED_AT:-$(now_iso)}"
        printf 'pipeline_run_epoch: %s\n' "${PIPELINE_RUN_EPOCH:-0}"
        printf 'updated_at: %s\n' "$(now_iso)"
        printf 'elapsed: %s\n' "${total_dur:-0s}"
        printf 'test_cmd: "%s"\n' "${TEST_CMD:-}"
        printf 'pr_number: %s\n' "${PR_NUMBER:-}"
        type get_effective_model >/dev/null 2>&1 && printf 'model: %s\n' "$(get_effective_model)" || true
        printf 'progress_comment_id: %s\n' "${PROGRESS_COMMENT_ID:-}"
        printf 'stages:\n'
        printf '%s' "${stages_yaml}"
        printf -- '---\n'
        printf '## Log\n'
        printf '%s\n' "$LOG_ENTRIES"
    } > "$tmp_state"
    mv -f "$tmp_state" "$STATE_FILE" || { rm -f "$tmp_state"; error "Failed to write pipeline state to $STATE_FILE (mv failed)"; return 1; }

    # Update pipeline_runs in DB
    if type update_pipeline_status >/dev/null 2>&1 && db_available 2>/dev/null; then
        local _job_id="${SHIPWRIGHT_PIPELINE_ID:-pipeline-$$-${ISSUE_NUMBER:-0}}"
        local _dur_secs=0
        if [[ -n "$PIPELINE_START_EPOCH" ]]; then
            _dur_secs=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
        fi
        update_pipeline_status "$_job_id" "$PIPELINE_STATUS" "$CURRENT_STAGE" "" "$_dur_secs" 2>/dev/null || true
    fi

}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No pipeline state found at $STATE_FILE"
        echo -e "  Start a new pipeline: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        exit 1
    fi

    info "Resuming pipeline from $STATE_FILE"

    # Explicitly clear outer/inner stage so old state files (which omit these fields)
    # don't inherit stale values from the environment, which would incorrectly trigger
    # the outer-stage resume handling in sw-pipeline.sh.
    OUTER_STAGE=""
    OUTER_STAGE_START_COMMIT=""
    INNER_STAGE=""

    local in_frontmatter=false
    local _has_original_goal=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)            PIPELINE_NAME="$(_trim "${line#pipeline:}")" ;;
                goal:*)
                    local _g _s=$'\001'
                    _g="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')"
                    _g="${_g//\\\\/$_s}"
                    _g="${_g//\\n/$'\n'}"
                    GOAL="${_g//$_s/\\}" ;;
                original_goal:*)
                    local _og _s2=$'\001'
                    _og="$(echo "${line#original_goal:}" | sed 's/^ *"//;s/" *$//')"
                    _og="${_og//\\\\/$_s2}"
                    _og="${_og//\\n/$'\n'}"
                    ORIGINAL_GOAL="${_og//$_s2/\\}"
                    _has_original_goal=true ;;
                status:*)              PIPELINE_STATUS="$(_trim "${line#status:}")" ;;
                issue:*)               GITHUB_ISSUE="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                branch:*)              GIT_BRANCH="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*)       CURRENT_STAGE="$(_trim "${line#current_stage:}")" ;;
                outer_stage:*)         OUTER_STAGE="$(_trim "${line#outer_stage:}")" ;;
                outer_stage_start_commit:*)  OUTER_STAGE_START_COMMIT="$(_trim "${line#outer_stage_start_commit:}")" ;;
                inner_stage:*)         INNER_STAGE="$(_trim "${line#inner_stage:}")" ;;
                current_stage_description:*) ;; # computed field — skip on resume
                stage_progress:*)      ;; # computed field — skip on resume
                started_at:*)          STARTED_AT="$(_trim "${line#started_at:}")" ;;
                test_cmd:*)            TEST_CMD="$(echo "${line#test_cmd:}" | sed 's/^ *"//;s/" *$//')" ;;
                pr_number:*)           PR_NUMBER="$(_trim "${line#pr_number:}")" ;;
                progress_comment_id:*) PROGRESS_COMMENT_ID="$(_trim "${line#progress_comment_id:}")" ;;
                pipeline_run_epoch:*)  PIPELINE_RUN_EPOCH="$(_trim "${line#pipeline_run_epoch:}")" ;;
                "  "*)
                    local trimmed
                    trimmed="$(_trim "$line")"
                    if [[ "$trimmed" == *":"* ]]; then
                        local sid="${trimmed%%:*}"
                        local sst="${trimmed#*: }"
                        [[ -n "$sid" && "$sid" != "stages" ]] && STAGE_STATUSES="${STAGE_STATUSES}
${sid}:${sst}"
                    fi
                    ;;
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

    # Backward compat: old state files won't have pipeline_run_epoch.
    # Derive epoch from the started_at timestamp already parsed above — this is the
    # stable anchor for "when this pipeline began" and won't drift like file mtime does.
    # If derivation fails we leave PIPELINE_RUN_EPOCH=0, which disables stale cleanup
    # (safe: no false deletions on upgrade).
    if [[ -z "${PIPELINE_RUN_EPOCH:-}" || "${PIPELINE_RUN_EPOCH:-0}" == "0" ]]; then
        if [[ -n "${STARTED_AT:-}" ]] && type date_to_epoch >/dev/null 2>&1; then
            local _derived_epoch
            _derived_epoch="$(date_to_epoch "$STARTED_AT" 2>/dev/null || true)"
            if [[ "$_derived_epoch" =~ ^[0-9]+$ && "$_derived_epoch" -gt "0" ]]; then
                PIPELINE_RUN_EPOCH="$_derived_epoch"
            fi
        fi
    fi

    # Remove artifacts that predate this pipeline run (handles artifacts left by a
    # different pipeline that previously used this worktree/artifacts directory).
    _cleanup_stale_artifacts_on_resume

    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    # Recovery: if stages section was empty (e.g., corrupted by signal during write),
    # reconstruct stage statuses from the log entries which record "complete (...)" lines.
    local trimmed_statuses
    trimmed_statuses="$(echo "$STAGE_STATUSES" | sed '/^$/d')"
    if [[ -z "$trimmed_statuses" && -n "$LOG_ENTRIES" ]]; then
        local recovered=""
        local stage_id=""
        while IFS= read -r log_line; do
            # Log entries like: "### intake (18:08:17)" set the current stage
            if [[ "$log_line" =~ ^###[[:space:]]+([a-z_]+)[[:space:]]+ ]]; then
                stage_id="${BASH_REMATCH[1]}"
            # Log entries like: "complete (2m 48s)" mark that stage as complete
            elif [[ -n "$stage_id" && "$log_line" =~ ^complete[[:space:]] ]]; then
                recovered="${recovered}
${stage_id}:complete"
                stage_id=""
            # "failed (...)" marks stage as failed
            elif [[ -n "$stage_id" && "$log_line" =~ ^failed[[:space:]] ]]; then
                recovered="${recovered}
${stage_id}:failed"
                stage_id=""
            fi
        done <<< "$LOG_ENTRIES"
        if [[ -n "$recovered" ]]; then
            STAGE_STATUSES="$recovered"
            warn "Recovered stage statuses from log (stages section was empty)"
        fi
    fi

    # Explicit --issue arg wins over state file. Only restore if CLI didn't set it.
    if [[ -z "${ISSUE_NUMBER:-}" ]] \
       && [[ -n "$GITHUB_ISSUE" && "$GITHUB_ISSUE" =~ ^#([0-9]+)$ ]]; then
        ISSUE_NUMBER="${BASH_REMATCH[1]}"
    fi
    [[ "${SHIPWRIGHT_DEBUG:-0}" == "1" ]] && echo "[ISSUE-TRACE] resume_state: ISSUE_NUMBER=${ISSUE_NUMBER:-<unset>} GITHUB_ISSUE=${GITHUB_ISSUE:-<unset>}" >&2 || true

    # Mismatch: state file belongs to a different issue than the CLI specified.
    # Only hard-fail when --issue was explicitly passed on the CLI (not inferred).
    if [[ "${_ISSUE_NUMBER_EXPLICIT:-false}" == "true" \
          && -n "${ISSUE_NUMBER:-}" && -n "$GITHUB_ISSUE" \
          && "$GITHUB_ISSUE" =~ ^#([0-9]+)$ \
          && "${BASH_REMATCH[1]}" != "$ISSUE_NUMBER" ]]; then
        error "Stale state: $STATE_FILE has issue=$GITHUB_ISSUE but pipeline launched with --issue $ISSUE_NUMBER. Remove the stale file and retry."
        return 2
    fi

    # Clear stale pipeline-tasks.md if it belongs to a different pipeline run.
    # Tasks are written by the plan stage and include "- Issue: #NNN" in a Context
    # section. If that issue doesn't match the current pipeline, the file is from a
    # previous run and must be removed to prevent stale context injection.
    if [[ -n "${TASKS_FILE:-}" && -f "$TASKS_FILE" ]]; then
        local _tasks_issue=""
        _tasks_issue=$(_trim "$(grep -m1 '^- Issue:' "$TASKS_FILE" 2>/dev/null | sed 's/^- Issue: *//')" || true)
        # Intake writes "- Issue: ${GITHUB_ISSUE:-none}" so normalize both sides:
        # treat an empty GITHUB_ISSUE as "none" to avoid deleting goal-based task files on resume.
        local _expected_issue="${GITHUB_ISSUE:-none}"
        if [[ -n "$_tasks_issue" && "$_tasks_issue" != "$_expected_issue" ]]; then
            rm -f "$TASKS_FILE"
        fi
    fi

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$PIPELINE_STATUS" == "complete" ]]; then
        warn "Pipeline already completed. Start a new one."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "aborted" ]]; then
        warn "Pipeline was aborted. Start a new one or edit the state file."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "interrupted" ]]; then
        info "Resuming from interruption..."
    fi

    if [[ -n "$GIT_BRANCH" ]]; then
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    fi

    PIPELINE_START_EPOCH="$(now_epoch)"
    gh_init
    load_pipeline_config
    PIPELINE_STATUS="running"
    success "Resumed pipeline: ${BOLD}$PIPELINE_NAME${RESET} — stage: $CURRENT_STAGE"
}

# ─── Task Type Detection ───────────────────────────────────────────────────

