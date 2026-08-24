#!/usr/bin/env bash
# core/router/permissions.sh — ADR-018 (#1919 C10): build acceptEdits settings file.
# Replaces --dangerously-skip-permissions at both spawn sites with a jq-validated
# settings file that grants write access only to the worktree and stage scratch dir.
# Sourced by route.sh after the env-scrub and base-include block.
#
# zbuild_engine_tmpdir is defined in scripts/lib/helpers.sh, which route.sh
# sources before loading this file.
# shellcheck source=../../scripts/lib/helpers.sh

[[ -n "${_ZBUILD_PERMISSIONS_LOADED:-}" ]] && return 0
_ZBUILD_PERMISSIONS_LOADED=1

# _zbuild_build_permissions_settings
# Writes ${ZBUILD_STAGE_SCRATCH:-$(zbuild_engine_tmpdir)}/claude-settings.json with
# allowedDirectories = [ZBUILD_REPO_ROOT, scratch_dir]. Validates with jq.
# Sets _ZBUILD_PERMISSIONS_SETTINGS_FILE to the written path.
# Returns rc=1 on jq parse failure (caller must abort spawn).
_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
_zbuild_build_permissions_settings() {
    local _scratch_dir
    if [[ -n "${ZBUILD_STAGE_SCRATCH:-}" ]]; then
        _scratch_dir="$ZBUILD_STAGE_SCRATCH"
    else
        _scratch_dir="$(zbuild_engine_tmpdir)"
        warn "router: permissions: ZBUILD_STAGE_SCRATCH unset, using engine tmpdir: $_scratch_dir"
    fi

    local _repo_root="${ZBUILD_REPO_ROOT:-}"
    if [[ -z "$_repo_root" ]]; then
        _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        [[ -z "$_repo_root" ]] && _repo_root="$(pwd)"
    fi

    local _settings_file="${_scratch_dir}/claude-settings.json"
    local _json
    _json="$(jq -cn \
        --arg repo "$_repo_root" \
        --arg scratch "$_scratch_dir" \
        '{permissions: {allowedDirectories: [$repo, $scratch]}}')" \
        || { error "router: permissions: jq failed to build settings JSON"; return 1; }

    printf '%s\n' "$_json" > "$_settings_file" \
        || { error "router: permissions: failed to write $_settings_file"; return 1; }

    # Validate the written file is parseable JSON.
    if ! jq empty "$_settings_file" 2>/dev/null; then
        error "router: permissions: settings file failed jq validation: $_settings_file"
        return 1
    fi

    _ZBUILD_PERMISSIONS_SETTINGS_FILE="$_settings_file"
    return 0
}

# _zbuild_permission_args
# Emits --permission-mode acceptEdits --settings <file> tokens for inline expansion.
# Caller must invoke _zbuild_build_permissions_settings first.
_zbuild_permission_args() {
    if [[ -z "${_ZBUILD_PERMISSIONS_SETTINGS_FILE:-}" ]]; then
        error "router: permissions: _zbuild_build_permissions_settings not called"
        return 1
    fi
    printf '%s\n' \
        "--permission-mode" "acceptEdits" \
        "--settings" "$_ZBUILD_PERMISSIONS_SETTINGS_FILE"
}
