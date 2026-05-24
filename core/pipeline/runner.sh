#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83, #208)
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
  --issue <N>       GitHub issue number to work
  --goal "<text>"   Pipeline goal description (alternative to --issue)
  --dry-run         Print the stage plan without executing anything
  --template <id>   Pipeline template to use (default: standard)
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

# Globals (not local) so EXIT trap can read them after main() returns.
_runner_run_id="" _runner_issue="" _runner_ended=false

main() {
    local issue="" goal="" dry_run=false template="standard"

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
            --dry-run)  dry_run=true;  shift ;;
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

    _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
    _runner_issue="${issue:-0}"
    _runner_ended=false
    export ZBUILD_RUN_ID="$_runner_run_id"
    export ZBUILD_ISSUE="$_runner_issue"

    # TODO(#35): Admission gate pending re-label to phase-0.5.
    mkdir -p "$state_dir"
    local state_file="$state_dir/pipeline-state.json"

    if ! init_state "$state_file" "$_runner_run_id" "$_runner_issue" 2>/dev/null; then
        warn "State file exists — clearing for fresh run (resume not yet implemented)"
        rm -f "$state_file" "${state_file}.bak" "${state_file}.lock"
        init_state "$state_file" "$_runner_run_id" "$_runner_issue"
    fi

    _runner_abort_trap() {
        [[ "$_runner_ended" == "true" ]] && return 0
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

    eb_emit_event "pipeline.start" "run_id=$_runner_run_id" "issue=$_runner_issue"
    info "Pipeline started — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-} template=$template"

    local stage
    for stage in "${active_stages[@]}"; do
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
                eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                    "run_id=$_runner_run_id" "issue=$_runner_issue"
                _runner_ended=true
                error "No plugin registered for required stage '$stage'"
                return 1
            fi
            set +e; plugin_hook_call "$plugin_dir" run "$stage" "$state_file"; rc=$?; set -e
        else
            local first_role; first_role="$(echo "$roles_out" | head -1)"
            if [[ "$strategy" == "composite" ]]; then
                error "Stage $stage: composite strategy not implemented (Phase 1 — deferred)"
                rc=1
            else
                local success_count=0 fail_count=0 any_plugin_found=false
                for platform in "${_DETECTED_PLATFORMS[@]}"; do
                    plugin_dir="$(resolve_plugin_for_role "$first_role" "$platform" "$plugins_root" 2>/dev/null || true)"
                    [[ -z "$plugin_dir" ]] && \
                        plugin_dir="$(resolve_plugin_for_role "$first_role" "" "$plugins_root" 2>/dev/null || true)"
                    [[ -z "$plugin_dir" ]] && continue
                    any_plugin_found=true
                    set +e
                    ZBUILD_PLATFORM="$platform" plugin_hook_call "$plugin_dir" run "$stage" "$state_file"
                    local prc=$?
                    set -e
                    if [[ $prc -eq 0 ]]; then
                        success_count=$((success_count + 1))
                    else
                        fail_count=$((fail_count + 1))
                        warn "Stage $stage failed on platform $platform (rc=$prc)"
                        [[ "$strategy" == "sequential" ]] && break
                    fi
                done

                if ! $any_plugin_found; then
                    # No role-based plugin found — fall back to direct ID match (backward-compat)
                    plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
                    if [[ -z "$plugin_dir" ]]; then
                        _update_stage_status "$state_file" "$stage" "failed"
                        eb_emit_event "stage.fail" "stage=$stage" "reason=no_plugin"
                        eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                            "run_id=$_runner_run_id" "issue=$_runner_issue"
                        _runner_ended=true
                        error "No plugin registered for required stage '$stage' (role: $first_role)"
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
        elif [[ $rc -eq 2 ]]; then
            # Partial: at least one platform succeeded and at least one failed
            _update_stage_status "$state_file" "$stage" "partial"
            eb_emit_event "stage.fail" "stage=$stage" "reason=partial"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            error "Stage $stage partially failed"
            return 1
        else
            # ADR-001: exit 1 (recoverable) and 2 (fatal) both halt v1.
            _update_stage_status "$state_file" "$stage" "failed"
            eb_emit_event "stage.fail" "stage=$stage" "rc=$rc"
            eb_emit_event "pipeline.end" "status=failed" "stage=$stage" "rc=$rc" \
                "run_id=$_runner_run_id" "issue=$_runner_issue"
            _runner_ended=true
            error "Stage $stage failed (rc=$rc)"
            return 1
        fi
    done

    eb_emit_event "pipeline.end" "status=success" "run_id=$_runner_run_id" "issue=$_runner_issue"
    _runner_ended=true
    success "Pipeline complete — run_id=$_runner_run_id"
    return 0
}

main "$@"
