#!/usr/bin/env bash
# core/pipeline/state_helpers.sh — runner-specific state helpers extracted
# from runner.sh (issue #279). Wraps core/state/atomic.sh's locked_state_update
# with runner-specific status conventions. No behavior change from the
# original runner-embedded versions.

[[ -n "${_ZBUILD_STATE_HELPERS_LOADED:-}" ]] && return 0
_ZBUILD_STATE_HELPERS_LOADED=1

_ZBUILD_STATE_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_STATE_HELPERS_ROOT="$(cd "$_ZBUILD_STATE_HELPERS_DIR/../.." && pwd)"

# Depends on locked_state_update (core/state/atomic.sh) and atomic_write
# (scripts/lib/helpers.sh). Defensively source each if absent — checking
# both because a test could stub one without the other (Copilot caught
# on #280: previously only locked_state_update was checked).
if ! declare -F locked_state_update >/dev/null 2>&1; then
    source "$_ZBUILD_STATE_HELPERS_ROOT/core/state/atomic.sh"
fi
if ! declare -F atomic_write >/dev/null 2>&1; then
    source "$_ZBUILD_STATE_HELPERS_ROOT/scripts/lib/helpers.sh"
fi

# write_scope_override — writes ZBUILD_SCOPE_PATHS (newline-delimited) to
# <state_dir>/scope-override.md as '+ <path>' fenced entries.
# Exported so tests can source this file and call it directly.
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

# _update_stage_status <state_file> <stage_id> <status>
# Atomically sets .stage_statuses[<stage_id>] = <status> and bumps .updated_at.
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
# Sets the top-level .status field atomically and bumps .updated_at.
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

# _set_pipeline_branch <state_file> <branch>
# Sets the top-level .branch field atomically and bumps .updated_at.
# Added for issue #484: intake creates a feature branch and records it in
# state so downstream stages (notably pr-open) can read it instead of
# re-deriving the name from the issue number.
_zbuild_runner_set_pipeline_branch() {
    jq --arg br "$_ZB_PIPELINE_BRANCH" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.branch = $br | .updated_at = $now'
}

_set_pipeline_branch() {
    export _ZB_PIPELINE_BRANCH="$2"
    locked_state_update "$1" "_zbuild_runner_set_pipeline_branch"
    unset _ZB_PIPELINE_BRANCH
}
