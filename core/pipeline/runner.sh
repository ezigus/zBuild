#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83, #208, #222, #225)
# ADR-001 (plugin contract), ADR-006 (resume contract), ADR-009 (platform-aware modularity),
# ADR-011 (pluggable orch backend)
set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/state/atomic.sh"
source "$_ZBUILD_ROOT/core/state/resume.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../config/config.sh
source "$_ZBUILD_ROOT/core/config/config.sh"
zbuild_config_init
# shellcheck source=../memory/contract.sh
source "$_ZBUILD_ROOT/core/memory/contract.sh"
memory_init || { echo "runner: memory backend failed to initialize" >&2; exit 2; }
source "$_ZBUILD_ROOT/core/detect/platforms.sh"
source "$_ZBUILD_ROOT/core/pipeline/template.sh"
source "$_ZBUILD_ROOT/core/pipeline/resolver.sh"
# shellcheck source=../orch/contract.sh
source "$_ZBUILD_ROOT/core/orch/contract.sh"
# Strategy modules (ADR-009 §fanout/sequential/composite, issue #222)
source "$_ZBUILD_ROOT/core/pipeline/strategies/fanout.sh"
source "$_ZBUILD_ROOT/core/pipeline/strategies/sequential.sh"
source "$_ZBUILD_ROOT/core/pipeline/strategies/composite.sh"

_usage() {
    cat <<EOF
Usage: runner.sh --issue <N>|--goal "<text>" [--dry-run] [--template <id>]
                 [--resume] [--from-stage <stage>] [--no-resume] [--force]
  --issue <N>       GitHub issue number to work
  --goal "<text>"   Pipeline goal description (alternative to --issue)
  --dry-run         Print the stage plan without executing anything
  --template <id>   Pipeline template to use (default: standard)
  --resume          Resume an existing run (skip completed stages)
  --from-stage <s>  Skip ahead to stage <s> when resuming (emits warning)
  --no-resume       Force fresh start even if an in_progress state exists
  --force           Resume even if status=aborted

Environment:
  ZBUILD_PLATFORM_OVERRIDE  Force a single platform; detection short-circuits.
  ZBUILD_SCOPE_PATHS        Newline-delimited scope paths; written as '+ <path>' entries.
EOF
}

_find_plugin_for_stage() {
    local stage="$1" plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}}" plugin_dir id
    while IFS= read -r plugin_dir; do
        id="$(yaml_get "$plugin_dir/manifest.yaml" "id")"
        [[ "$id" == "$stage" ]] && { echo "$plugin_dir"; return 0; }
    done < <(discover_plugins "$plugins_root" 2>/dev/null)
    return 1
}

# _check_artifact_contract <plugin_dir> <state_dir> <stage>
# ARCHITECTURE.md §2: if a plugin declares provides.artifact_type, it MUST
# write the declared output artifact. Emits plugin.contract.violated and
# creates a synthetic blocking findings.json if the artifact is missing/empty.
# Returns 0 always (caller decides whether to halt the pipeline).
_check_artifact_contract() {
    local plugin_dir="$1" state_dir="$2" stage="$3"
    local manifest="$plugin_dir/manifest.yaml"

    # Check if plugin declares provides.artifact_type
    local artifact_type
    artifact_type="$(yaml_get "$manifest" "provides.artifact_type" 2>/dev/null || true)"
    [[ -z "$artifact_type" ]] && return 0

    # Get declared output path (first outputs[].path entry)
    local output_path
    output_path="$(awk '
        /^outputs:/ { in_outputs=1; next }
        in_outputs && /^[a-zA-Z_]/ { in_outputs=0 }
        in_outputs && /path:/ {
            sub(/^[[:space:]]*path:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            print
            exit
        }
    ' "$manifest" 2>/dev/null || true)"

    # Resolve path relative to state_dir if not absolute
    local resolved_path
    if [[ -n "$output_path" ]]; then
        if [[ "$output_path" == /* ]]; then
            resolved_path="$output_path"
        else
            resolved_path="$state_dir/$output_path"
        fi
    else
        # No explicit output path declared — check for state_dir/artifacts/<stage>-findings.json
        resolved_path="$state_dir/artifacts/${stage}-findings.json"
    fi

    # Check if artifact exists and is non-empty
    if [[ -s "$resolved_path" ]]; then
        return 0  # artifact present and non-empty — contract satisfied
    fi

    local plugin_id; plugin_id="$(yaml_get "$manifest" "id" 2>/dev/null || true)"

    # Emit plugin.contract.violated event
    eb_emit_event "plugin.contract.violated" \
        "stage=$stage" \
        "plugin=${plugin_id:-unknown}" \
        "artifact_type=$artifact_type" \
        "expected_path=$resolved_path" \
        "reason=artifact_missing_or_empty"

    # Create synthetic blocking findings.json under artifacts/ so the output
    # plugin's aggregator (which reads $state_dir/artifacts/*-findings.json) picks it up
    mkdir -p "$state_dir/artifacts"
    local findings_file="$state_dir/artifacts/${stage}-contract-violated-findings.json"
    jq -n \
        --arg stage "$stage" \
        --arg plugin "${plugin_id:-unknown}" \
        --arg artifact_type "$artifact_type" \
        --arg path "$resolved_path" \
        '{
            schema_version: 1,
            findings: [{
                id: "artifact-contract-violated",
                title: ("Plugin contract violated: " + $plugin + " declared provides.artifact_type=" + $artifact_type + " but wrote no artifact"),
                severity: "blocking",
                stage: $stage,
                plugin: $plugin,
                detail: ("Expected artifact at: " + $path)
            }]
        }' > "$findings_file" 2>/dev/null || true

    warn "Plugin contract violated: $plugin_id (stage=$stage) declared artifact_type=$artifact_type but wrote no artifact at $resolved_path"
    return 0
}

# write_scope_override — writes ZBUILD_SCOPE_PATHS (newline-delimited) to
# <state_dir>/scope-override.md as '+ <path>' fenced entries.
# Exported so tests can source runner.sh and call it directly.
# Usage: write_scope_override <state_dir> <run_id>
write_scope_override() {
    local state_dir="$1" run_id="${2:-}"
    [[ -z "$state_dir" ]] && return 1
    [[ -z "${ZBUILD_SCOPE_PATHS:-}" ]] && return 0
    local scope_override="$state_dir/scope-override.md"
    {
        echo "# Scope Override"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# run_id: $run_id"
        echo ""
        while IFS= read -r scope_path; do
            [[ -z "$scope_path" ]] && continue
            printf '+ %s\n' "$scope_path"
        done <<< "$ZBUILD_SCOPE_PATHS"
    } | atomic_write "$scope_override"
}

_zbuild_runner_set_stage_status() {
    jq --arg id "$_ZB_STAGE_ID" --arg st "$_ZB_STAGE_STATUS" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.stage_statuses[$id] = $st | .updated_at = $now'
}

_update_stage_status() {
    export _ZB_STAGE_ID="$2" _ZB_STAGE_STATUS="$3"
    locked_state_update "$1" "_zbuild_runner_set_stage_status"
    unset _ZB_STAGE_ID _ZB_STAGE_STATUS
}

# _set_pipeline_status <state_file> <status>
# Sets the top-level .status field atomically.
_zbuild_runner_set_pipeline_status() {
    jq --arg st "$_ZB_PIPELINE_STATUS" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.status = $st | .updated_at = $now'
}

_set_pipeline_status() {
    export _ZB_PIPELINE_STATUS="$2"
    locked_state_update "$1" "_zbuild_runner_set_pipeline_status"
    unset _ZB_PIPELINE_STATUS
}


# Globals (not local) so EXIT trap can read them after main() returns.
_runner_run_id="" _runner_issue="" _runner_ended=false _runner_state_file=""

main() {
    local issue="" goal="" dry_run=false template="standard"
    local resume_mode=false from_stage="" no_resume=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                [[ -z "${2:-}" ]] && { error "--issue requires a value"; _usage; return 2; }
                issue="$2"; shift 2 ;;
            --goal)
                [[ -z "${2:-}" ]] && { error "--goal requires a value"; _usage; return 2; }
                goal="$2"; shift 2 ;;
            --template)
                [[ -z "${2:-}" ]] && { error "--template requires a value"; _usage; return 2; }
                template="$2"; shift 2 ;;
            --dry-run)    dry_run=true;    shift ;;
            --resume)     resume_mode=true; shift ;;
            --no-resume)  no_resume=true;  shift ;;
            --force)      force=true;      shift ;;
            --from-stage)
                [[ -z "${2:-}" ]] && { error "--from-stage requires a value"; _usage; return 2; }
                from_stage="$2"; shift 2 ;;
            --help|-h)  _usage; return 0 ;;
            *) error "Unknown argument: $1"; _usage; return 2 ;;
        esac
    done

    if [[ -z "$issue" && -z "$goal" ]]; then
        error "Must specify --issue <N> or --goal \"<text>\""
        _usage
        return 2
    fi

    # --from-stage is only valid in resume mode
    if [[ -n "$from_stage" ]] && ! $resume_mode; then
        error "--from-stage is only valid with --resume"
        _usage
        return 2
    fi

    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
    local template_file="$_ZBUILD_ROOT/config/templates/${template}.yaml"

    # Load template; fall back to built-in stage list if template missing or empty
    local active_stages=()
    if load_template "$template_file" 2>/dev/null && [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
        active_stages=("${_TPL_STAGES[@]}")
    else
        warn "Template '$template' not found; using built-in stage list"
        active_stages=(intake security-lens output)
    fi

    if $dry_run; then
        info "Pipeline plan (dry-run, template=$template) — issue=${issue:-} goal=${goal:-}"
        local stage roles_out role plugin_dir pd
        for stage in "${active_stages[@]}"; do
            # Intentional fail-open (dry-run display only; missing template/plugin not fatal here)
            roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
            if [[ -z "$roles_out" ]]; then
                # Intentional fail-open: dry-run lookup; empty result displayed as "(no plugin registered)"
                plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                [[ -n "$plugin_dir" ]] \
                    && printf "  stage: %-20s → plugin: %s\n" "$stage" "$(basename "$plugin_dir")" \
                    || printf "  stage: %-20s → (no plugin registered)\n" "$stage"
            else
                while IFS= read -r role; do
                    [[ -z "$role" ]] && continue
                    # Intentional fail-open: dry-run role lookup; empty = display "(no plugin for role)"
                    pd="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
                    if [[ -z "$pd" ]]; then
                        # Role resolver found nothing; try direct ID match for display
                        # Intentional fail-open: display fallback only
                        pd="$(_find_plugin_for_stage "$stage" "$plugins_root" 2>/dev/null || true)"
                    fi
                    [[ -n "$pd" ]] \
                        && printf "  stage: %-20s role: %-20s → plugin: %s\n" "$stage" "$role" "$(basename "$pd")" \
                        || printf "  stage: %-20s role: %-20s → (no plugin for role)\n" "$stage" "$role"
                done <<< "$roles_out"
            fi
        done
        return 0
    fi

    mkdir -p "$state_dir"
    # Honor ZBUILD_STATE_FILE when set (e.g. by `pipeline resume --run-id`)
    local state_file
    if [[ -n "${ZBUILD_STATE_FILE:-}" ]]; then
        state_file="$ZBUILD_STATE_FILE"
        state_dir="$(dirname "$state_file")"
    else
        state_file="$state_dir/pipeline-state.json"
    fi
    _runner_state_file="$state_file"

    # Validate --from-stage against active_stages now that we have the stage list
    if [[ -n "$from_stage" ]]; then
        local _fs_valid=false _fs_s
        for _fs_s in "${active_stages[@]}"; do
            [[ "$_fs_s" == "$from_stage" ]] && { _fs_valid=true; break; }
        done
        if ! $_fs_valid; then
            error "--from-stage '$from_stage' is not a known stage (active stages: ${active_stages[*]})"
            return 2
        fi
    fi

    # ── Resume / fresh-start policy ────────────────────────────────────────────
    if $resume_mode; then
        # Explicit --resume: check state exists and honour --force for aborted
        if [[ ! -f "$state_file" ]]; then
            error "No state file found at $state_file; cannot resume"
            return 1
        fi
        local existing_status
        existing_status="$(get_state_field "$state_file" '.status' '')"
        if [[ "$existing_status" == "aborted" ]] && ! $force; then
            error "Pipeline status is 'aborted'; use --force to resume anyway"
            return 1
        fi
        if [[ "$existing_status" == "complete" ]]; then
            warn "Pipeline status is 'complete'; starting fresh"
            resume_mode=false
        else
            # Restore run_id and issue from existing state
            _runner_run_id="$(get_state_field "$state_file" '.run_id' "$(date +%Y%m%d%H%M%S)-$$")"
            _runner_issue="$(get_state_field "$state_file" '.issue' '0')"
        fi
    elif ! $no_resume && [[ -f "$state_file" ]]; then
        # Auto-resume policy
        local recommendation
        recommendation="$(get_resume_recommendation "$state_file")"
        case "$recommendation" in
            auto_resume)
                info "Auto-resuming previous run (use --no-resume to force fresh start)"
                resume_mode=true
                _runner_run_id="$(get_state_field "$state_file" '.run_id' "$(date +%Y%m%d%H%M%S)-$$")"
                _runner_issue="$(get_state_field "$state_file" '.issue' '0')"
                ;;
            manual_resume_only)
                info "Previous run requires explicit --resume (or --force for aborted)"
                resume_mode=false
                ;;
            fresh_start|*)
                resume_mode=false
                ;;
        esac
    fi

    if ! $resume_mode; then
        # Fresh start: clear any existing state
        if [[ -f "$state_file" ]]; then
            rm -f "$state_file" "${state_file}.bak" "${state_file}.lock"
        fi
        # Sanitize ZBUILD_RUN_ID: strip characters unsafe in filenames (/, .., spaces, etc.)
        # to prevent path traversal when run_id is used in report-${run_id}.md filenames.
        local _raw_run_id="${ZBUILD_RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
        _runner_run_id="${_raw_run_id//[^a-zA-Z0-9_.-]/}"
        # Fall back to generated ID if sanitization emptied the value
        [[ -z "$_runner_run_id" ]] && _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
        _runner_issue="${issue:-0}"
        init_state "$state_file" "$_runner_run_id" "$_runner_issue"
        # Persist goal so resume can reconstruct the correct runner args.
        # Use jq --arg to safely encode user-supplied goal (prevents JSON injection
        # from embedded quotes or other special characters in the goal string).
        if [[ -n "${goal:-}" ]]; then
            set_state_field "$state_file" '.goal' "$(jq -n --arg g "$goal" '$g')"
        fi
    fi

    _runner_ended=false
    export ZBUILD_RUN_ID="$_runner_run_id"
    export ZBUILD_ISSUE="$_runner_issue"
    export ZBUILD_GOAL="${goal:-}"

    # Mark pipeline as in_progress
    _set_pipeline_status "$state_file" "in_progress"

    # Write user-provided scope paths to scope-override.md in '+ <path>' format.
    # After the intake stage completes, these entries are appended to scope-manifest.md
    # so intake's platform detection is preserved alongside the operator override.
    if [[ -n "${ZBUILD_SCOPE_PATHS:-}" ]]; then
        write_scope_override "$state_dir" "$_runner_run_id"
        info "Scope override paths written to $state_dir/scope-override.md"
    fi

    _runner_abort_trap() {
        [[ "$_runner_ended" == "true" ]] && return 0
        # Clean teardown (signal/OOM) → interrupted; operator cancel → aborted handled elsewhere.
        # Fail-closed: if we cannot mark the pipeline interrupted, emit an error event so the
        # operator can detect the unrecorded abort (was: || true, which silently dropped failures).
        if ! _set_pipeline_status "$_runner_state_file" "interrupted" 2>/dev/null; then
            eb_emit_event "pipeline.state.error" \
                "run_id=$_runner_run_id" "issue=$_runner_issue" \
                "reason=abort_trap_set_status_failed" 2>/dev/null || true
        fi
        # Fail-closed: if abort event cannot be emitted, that is still non-fatal for the trap
        # itself (the process is exiting), but we do not silently swallow the failure.
        if ! eb_emit_event "pipeline.abort" \
            "run_id=$_runner_run_id" "issue=$_runner_issue" 2>/dev/null; then
            : # trap is exiting anyway; best-effort only
        fi
    }
    trap '_runner_abort_trap' EXIT

    # Detect platforms (writes state/platforms.json; returns "generic" if none found)
    local _DETECTED_PLATFORMS=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && _DETECTED_PLATFORMS+=("$p")
    done < <(detect_platforms "$PWD" "$state_dir" 2>/dev/null)
    [[ ${#_DETECTED_PLATFORMS[@]} -eq 0 ]] && _DETECTED_PLATFORMS=("generic")

    if $resume_mode; then
        eb_emit_event "pipeline.resume" "run_id=$_runner_run_id" "issue=$_runner_issue"
        info "Pipeline resuming — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-} template=$template"
        if [[ -n "$from_stage" ]]; then
            warn "Skipping ahead to stage '$from_stage' as requested (--from-stage)"
            eb_emit_event "pipeline.skip_to_stage" "stage=$from_stage" "run_id=$_runner_run_id"
        fi
    else
        eb_emit_event "pipeline.start" "run_id=$_runner_run_id" "issue=$_runner_issue"
        info "Pipeline started — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-} template=$template"
    fi

    # ── Determine skip-ahead point when --from-stage is set ───────────────────
    local skip_until_stage=""
    [[ -n "$from_stage" ]] && skip_until_stage="$from_stage"

    local stage
    for stage in "${active_stages[@]}"; do
        # When resuming, skip stages already marked complete unless --from-stage overrides
        if $resume_mode && [[ -z "$skip_until_stage" ]]; then
            local stage_status
            stage_status="$(get_state_field "$state_file" ".stage_statuses[\"$stage\"]" '')"
            if [[ "$stage_status" == "complete" ]]; then
                info "Skipping already-complete stage: $stage"
                continue
            fi
        fi

        # --from-stage: skip until we reach the named stage
        if [[ -n "$skip_until_stage" && "$stage" != "$skip_until_stage" ]]; then
            info "Skipping stage: $stage (awaiting $skip_until_stage)"
            continue
        fi
        # Once we reach the target stage, clear the skip gate
        skip_until_stage=""

        eb_emit_event "stage.start" "stage=$stage"
        info "Running stage: $stage"

        # Intentional fail-open: missing/empty template roles = no-template path (handled below)
        local roles_out; roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
        local strategy; strategy="$(template_stage_strategy "$stage" 2>/dev/null || echo "fanout")"
        local plugin_dir="" rc=0

        if [[ -z "$roles_out" ]]; then
            # No roles in template — resolve by stage ID (backward-compat).
            # Intentional fail-open: _find_plugin_for_stage returns non-zero when not found;
            # the empty-result branch below emits stage.fail and halts the pipeline (fail-closed).
            plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
            if [[ -z "$plugin_dir" ]]; then
                _update_stage_status "$state_file" "$stage" "failed"
                _set_pipeline_status "$state_file" "interrupted"
                eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _runner_ended=true
                error "No plugin registered for required stage '$stage'"
                return 1
            fi
            set +e; plugin_hook_call "$plugin_dir" run "$stage" "$state_file"; rc=$?; set -e
            # ARCHITECTURE.md §2: enforce artifact contract after plugin run (fail-closed)
            if [[ $rc -eq 0 ]]; then
                _check_artifact_contract "$plugin_dir" "$state_dir" "$stage"
            fi
        else
            # Strategy dispatch via orch contract (ADR-011, issue #222).
            # Pool ID: stage-scoped, unique per run to prevent pool collision across stages.
            local pool_id
            pool_id="zbuild-${stage}-$$-$(date +%s%N 2>/dev/null || date +%s)"
            orch_spawn "$pool_id" || {
                _update_stage_status "$state_file" "$stage" "failed"
                _set_pipeline_status "$state_file" "interrupted"
                eb_emit_event "stage.fail" "stage=$stage" "reason=orch_spawn_failed"
                eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _runner_ended=true
                error "Stage $stage: orch_spawn failed for pool $pool_id"
                return 1
            }

            # Allow _ZBUILD_STRATEGY_OVERRIDE for testing; normal path reads $strategy.
            local _effective_strategy="${_ZBUILD_STRATEGY_OVERRIDE:-$strategy}"

            rc=0
            case "$_effective_strategy" in
                composite)
                    set +e; _strategy_run_composite "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
                sequential)
                    set +e; _strategy_run_sequential "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
                *)
                    # fanout (default) — parallel dispatch
                    set +e; _strategy_run_fanout "$pool_id" "$stage" "$roles_out" "$state_file" "$plugins_root"; rc=$?; set -e
                    ;;
            esac

            # rc=4 from strategy means "no plugin found for any role" — fall back to direct ID
            # match (backward-compat for plugins named by stage ID rather than role).
            # rc=1/2 are execution failures; the fallback must NOT fire for those, or a failed
            # role-based stage could be silently masked by a passing stage-id plugin.
            if [[ $rc -eq 4 ]]; then
                plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                if [[ -z "$plugin_dir" ]]; then
                    _update_stage_status "$state_file" "$stage" "failed"
                    _set_pipeline_status "$state_file" "interrupted"
                    eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                    eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                        "run_id=$_runner_run_id" "issue=$_runner_issue"
                    _runner_ended=true
                    error "No plugin registered for required stage '$stage' (roles: $roles_out)"
                    return 1
                fi
                set +e; plugin_hook_call "$plugin_dir" run "$stage" "$state_file"; rc=$?; set -e
                # ARCHITECTURE.md §2: enforce artifact contract after plugin run (fail-closed)
                if [[ $rc -eq 0 ]]; then
                    _check_artifact_contract "$plugin_dir" "$state_dir" "$stage"
                fi
            fi
            # rc=0: artifact contracts already checked inside fanout/sequential strategies.
        fi

        if [[ $rc -eq 0 ]]; then
            _update_stage_status "$state_file" "$stage" "complete"
            eb_emit_event "stage.complete" "stage=$stage"
            success "Stage $stage complete"
            # After intake completes, append user-provided scope overrides to
            # scope-manifest.md so intake's detection output is preserved alongside
            # the operator's --scope paths.
            if [[ "$stage" == "intake" && -f "$state_dir/scope-override.md" ]]; then
                local scope_manifest="$state_dir/scope-manifest.md"
                # Extract only '+ <path>' lines from the override file and append.
                # Intentional fail-open: scope-override.md may not exist (no --scope flag used)
                grep '^+ ' "$state_dir/scope-override.md" >> "$scope_manifest" 2>/dev/null || true
                info "Appended scope override entries to $scope_manifest"
            fi
        elif [[ $rc -eq 2 ]]; then
            # Partial fanout: at least one platform succeeded and at least one failed.
            # State uses "failed" (ADR-006 enum); partial detail is in the event payload.
            _update_stage_status "$state_file" "$stage" "failed"
            _set_pipeline_status "$state_file" "interrupted"
            eb_emit_event "stage.fail" "stage=$stage" "reason=partial"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            error "Stage $stage partially failed"
            return 1
        else
            # ADR-001: exit 1 (recoverable) and 2 (fatal) both halt v1.
            _update_stage_status "$state_file" "$stage" "failed"
            _set_pipeline_status "$state_file" "interrupted"
            eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" "rc=$rc" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            error "Stage $stage failed (rc=$rc)"
            return 1
        fi
    done

    _set_pipeline_status "$state_file" "complete"
    eb_emit_event "pipeline.end" "status=success" "run_id=$_runner_run_id" "issue=$_runner_issue"
    _runner_ended=true
    success "Pipeline complete — run_id=$_runner_run_id"
    return 0
}

# Only run main when executed directly, not when sourced for function access.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
