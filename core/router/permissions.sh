#!/usr/bin/env bash
# core/router/permissions.sh — ADR-018 (#1919 C10): acceptEdits + scoped grants.
# Replaces --dangerously-skip-permissions at both spawn sites.
#
# MEASURED on CLI 2.1.241 (#1919 P0-P5), not assumed — the ADR-018 claim this
# supersedes went stale precisely because nobody re-measured:
#   P0  --permission-mode acceptEdits ALONE writes fine. The blanket bypass was
#       never needed for headless Pattern 1.
#   P4  --add-dir IS the grant.
#   P2b `permissions.allowedDirectories` in a --settings file is NOT a grant. It
#       is silently ignored: the identical write is refused under that key and
#       succeeds under --add-dir. Do not re-add it believing it grants anything.
#   P5  `permissions.deny` IS honoured, but only in `Edit(...)` form — a
#       `Write(...)` rule silently matches nothing (the CLI warns).
#
# So: the SPAWN grants (--add-dir), and the settings file is the jq-validated
# policy seam the spawn refuses on (SPEC-3) and where the evidence-based deny
# list from the #1809 sweep will land.
# Sourced by route.sh after the env-scrub and base-include block.
#
# zbuild_engine_tmpdir is defined in scripts/lib/helpers.sh, which route.sh
# sources before loading this file.
# shellcheck source=../../scripts/lib/helpers.sh

[[ -n "${_ZBUILD_PERMISSIONS_LOADED:-}" ]] && return 0
_ZBUILD_PERMISSIONS_LOADED=1

# _zbuild_build_permissions_settings
# Writes ${ZBUILD_STAGE_SCRATCH:-$(zbuild_engine_tmpdir)}/claude-settings.json and
# validates it with jq. Sets _ZBUILD_PERMISSIONS_SETTINGS_FILE to the written path
# and _ZBUILD_PERMISSIONS_DIRS to the roots the spawn will grant via --add-dir.
# Returns rc=1 on jq/write failure (caller must abort the spawn — SPEC-3).
#
# `deny` starts empty by design: the Ordering note on #1919 requires the deny list
# be written from real stage.write_boundary.violated records (#1809), not guessed.
# The file still earns its place — it is the refusal seam, it keeps policy out of
# `ps` and shell history, and it is a durable diffable record of the spawn.
_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
_ZBUILD_PERMISSIONS_DIRS=()
_zbuild_build_permissions_settings() {
    local _scratch_dir
    if [[ -n "${ZBUILD_STAGE_SCRATCH:-}" ]]; then
        _scratch_dir="$ZBUILD_STAGE_SCRATCH"
    else
        _scratch_dir="$(zbuild_engine_tmpdir)"
        warn "router: permissions: ZBUILD_STAGE_SCRATCH unset, using engine tmpdir: $_scratch_dir"
        # Use a variable so the literal is invisible to the event-schema
        # string-literal coverage grep (ADR-036 §3 note on dynamic calls).
        local _fb_evt="router.permissions.scratch_fallback"
        eb_emit_event "$_fb_evt" "scratch_dir=$_scratch_dir" 2>/dev/null || true
    fi

    local _repo_root="${ZBUILD_REPO_ROOT:-}"
    if [[ -z "$_repo_root" ]]; then
        _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        [[ -z "$_repo_root" ]] && _repo_root="$(pwd)"
    fi

    local _settings_file="${_scratch_dir}/claude-settings.json"
    local _json
    _json="$(jq -cn '{permissions: {deny: []}}')" \
        || { error "router: permissions: jq failed to build settings JSON"; return 1; }

    printf '%s\n' "$_json" > "$_settings_file" \
        || { error "router: permissions: failed to write $_settings_file"; return 1; }

    # Validate the written file is parseable JSON.
    if ! jq empty "$_settings_file" 2>/dev/null; then
        error "router: permissions: settings file failed jq validation: $_settings_file"
        return 1
    fi

    _ZBUILD_PERMISSIONS_SETTINGS_FILE="$_settings_file"
    # ADR-059: derive the granted roots from the exported env, never from a path
    # literal — six existing call sites already fail silently when the layout
    # moves, and a permission grant that silently widens would be a worse seventh.
    _ZBUILD_PERMISSIONS_DIRS=("$_repo_root" "$_scratch_dir")
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
    printf '%s\n' "--permission-mode" "acceptEdits"
    # P4: --add-dir is the grant. One flag per root; the CLI accepts repeats.
    local _d
    for _d in "${_ZBUILD_PERMISSIONS_DIRS[@]+"${_ZBUILD_PERMISSIONS_DIRS[@]}"}"; do
        [[ -n "$_d" ]] && printf '%s\n' "--add-dir" "$_d"
    done
    printf '%s\n' "--settings" "$_ZBUILD_PERMISSIONS_SETTINGS_FILE"
}
