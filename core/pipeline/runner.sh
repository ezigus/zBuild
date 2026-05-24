#!/usr/bin/env bash
# core/pipeline/runner.sh — Pipeline orchestrator (issue #83)
# Ties together: state, event-bus, plugin-registry.
# ADR-001 (plugin contract), ADR-006 (resume contract)
set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_RUNNER_DIR/../.." && pwd)"

source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
source "$_ZBUILD_ROOT/core/state/atomic.sh"
source "$_ZBUILD_ROOT/core/state/resume.sh"
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"

# MVP stage list — hardcoded array. Stage-list-as-config is Phase 1.
_PIPELINE_STAGES=(intake security-lens output)

_usage() {
    cat <<EOF
Usage: runner.sh --issue <N>|--goal "<text>" [--dry-run]
  --issue <N>       GitHub issue number to work
  --goal "<text>"   Pipeline goal description (alternative to --issue)
  --dry-run         Print the stage plan without executing anything
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

main() {
    local issue="" goal="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                [[ -z "${2:-}" ]] && { error "--issue requires a value"; _usage; return 2; }
                issue="$2"; shift 2 ;;
            --goal)
                [[ -z "${2:-}" ]] && { error "--goal requires a value"; _usage; return 2; }
                goal="$2"; shift 2 ;;
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

    if $dry_run; then
        info "Pipeline plan (dry-run) — issue=${issue:-} goal=${goal:-}"
        local stage plugin_dir
        for stage in "${_PIPELINE_STAGES[@]}"; do
            plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" || true)"
            if [[ -n "$plugin_dir" ]]; then
                printf "  stage: %-20s → plugin: %s\n" "$stage" "$(basename "$plugin_dir")"
            else
                printf "  stage: %-20s → (no plugin registered)\n" "$stage"
            fi
        done
        return 0
    fi

    # Globals (not local) so EXIT trap can read them after main() returns.
    _runner_run_id="$(date +%Y%m%d%H%M%S)-$$"
    _runner_issue="${issue:-0}"
    _runner_ended=false
    export ZBUILD_RUN_ID="$_runner_run_id"
    export ZBUILD_ISSUE="$_runner_issue"

    # TODO(#35): Admission gate pending re-label to phase-0.5.
    # Two concurrent runs will clobber pipeline-state.json until #35 lands.
    local state_dir="${ZBUILD_STATE_DIR:-$HOME/.zbuild/state}"
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

    eb_emit_event "pipeline.start" "run_id=$_runner_run_id" "issue=$_runner_issue"
    info "Pipeline started — run_id=$_runner_run_id issue=${issue:-} goal=${goal:-}"

    local stage plugin_dir rc
    for stage in "${_PIPELINE_STAGES[@]}"; do
        eb_emit_event "stage.start" "stage=$stage"
        info "Running stage: $stage"
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

        if [[ $rc -eq 0 ]]; then
            _update_stage_status "$state_file" "$stage" "complete"
            eb_emit_event "stage.complete" "stage=$stage"
            success "Stage $stage complete"
        else
            # ADR-001: exit 1 (recoverable) and 2 (fatal) both halt v1.
            # Retry/recovery routing is deferred (follow-on issue, depends_on: 83).
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
