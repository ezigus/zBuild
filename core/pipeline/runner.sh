#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83, #208, #225)
# ADR-001 (plugin contract), ADR-006 (resume contract), ADR-009 (platform-aware modularity)
set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/state/atomic.sh"
source "$_ZBUILD_ROOT/core/state/resume.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"
source "$_ZBUILD_ROOT/core/detect/platforms.sh"
source "$_ZBUILD_ROOT/core/pipeline/template.sh"
source "$_ZBUILD_ROOT/core/pipeline/resolver.sh"

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
            roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
            if [[ -z "$roles_out" ]]; then
                plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                [[ -n "$plugin_dir" ]] \
                    && printf "  stage: %-20s → plugin: %s\n" "$stage" "$(basename "$plugin_dir")" \
                    || printf "  stage: %-20s → (no plugin registered)\n" "$stage"
            else
                while IFS= read -r role; do
                    [[ -z "$role" ]] && continue
                    pd="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
                    if [[ -z "$pd" ]]; then
                        # Role resolver found nothing; try direct ID match for display
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
    local state_file="$state_dir/pipeline-state.json"
    _runner_state_file="$state_file"

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
        _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
        _runner_issue="${issue:-0}"
        init_state "$state_file" "$_runner_run_id" "$_runner_issue"
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
        # Clean teardown (signal/OOM) → interrupted; operator cancel → aborted handled elsewhere
        _set_pipeline_status "$_runner_state_file" "interrupted" 2>/dev/null || true
        eb_emit_event "pipeline.abort" \
            "run_id=$_runner_run_id" "issue=$_runner_issue" 2>/dev/null || true
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

        local roles_out; roles_out="$(template_stage_roles "$stage" 2>/dev/null || true)"
        local strategy; strategy="$(template_stage_strategy "$stage" 2>/dev/null || echo "fanout")"
        local plugin_dir="" rc=0

        if [[ -z "$roles_out" ]]; then
            # No roles in template — resolve by stage ID (backward-compat)
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
        else
            if [[ "$strategy" == "composite" ]]; then
                error "Stage $stage: composite strategy not implemented (Phase 1 — deferred)"
                rc=1
            else
                local success_count=0 fail_count=0 any_plugin_found=false break_all=false role
                while IFS= read -r role; do
                    [[ -z "$role" ]] && continue
                    $break_all && break
                    for platform in "${_DETECTED_PLATFORMS[@]}"; do
                        plugin_dir="$(resolve_plugin_for_role "$role" "$platform" "$plugins_root" 2>/dev/null || true)"
                        [[ -z "$plugin_dir" ]] && \
                            plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
                        [[ -z "$plugin_dir" ]] && continue
                        any_plugin_found=true
                        set +e
                        ZBUILD_TARGET_PLATFORM="$platform" plugin_hook_call "$plugin_dir" run "$stage" "$state_file"
                        local prc=$?
                        set -e
                        if [[ $prc -eq 0 ]]; then
                            success_count=$((success_count + 1))
                        else
                            fail_count=$((fail_count + 1))
                            warn "Stage $stage role $role failed on platform $platform (rc=$prc)"
                            if [[ "$strategy" == "sequential" ]]; then
                                break_all=true; break
                            fi
                        fi
                    done
                done <<< "$roles_out"

                if ! $any_plugin_found; then
                    # No role-based plugin found — fall back to direct ID match (backward-compat)
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
                else
                    if   [[ $fail_count -eq 0 ]]; then   rc=0
                    elif [[ $success_count -gt 0 ]]; then rc=2
                    else                                  rc=1
                    fi
                fi
            fi
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
