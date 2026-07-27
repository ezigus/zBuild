#!/usr/bin/env bash
# scripts/lib/persona-resolve.sh — resolve a stage's persona directory from the
# ADR-051 §5 precedence chain and a two-root discovery scan.
#
# Public functions:
#   resolve_persona <stage_id>
#     Walks the four-step precedence chain:
#       1. ZBUILD_<STAGE>_PERSONA env (stage_id uppercased, '-'→'_')
#       2. template_stage_router_persona (per-stage template binding)
#       3. template_config_persona (global template default)
#       4. id=generic (terminal fallback)
#     For the resolved id, scans two roots:
#       - installed: ${ZBUILD_PLUGINS_ROOT:-<repo>/plugins}
#       - repo overlay: ${ZBUILD_REPO_ROOT:-git rev-parse --show-toplevel}/.zbuild/plugins
#     Overlay wins on id collision; absent overlay dir is silent (no error).
#     The overlay scan uses a LOCAL variable — never ZBUILD_PLUGINS_ROOT (ADR-024).
#     If the resolved id is absent from both roots, falls back to id=generic.
#     Prints the persona directory path; returns 0 on success, 1 if not found.
#
#   persona_text <persona_dir>
#     Reads persona.perspective from <persona_dir>/manifest.yaml via yaml_get.
#     Prints the value (may be empty for a neutral/generic persona).
#     Returns 0 even when perspective is empty.
#
# Sourced library: no set -euo pipefail (would mutate the caller's shell options).

[[ -n "${_ZBUILD_PERSONA_RESOLVE_LOADED:-}" ]] && return 0
_ZBUILD_PERSONA_RESOLVE_LOADED=1

_PERSONA_RESOLVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PERSONA_RESOLVE_ROOT="$(cd "$_PERSONA_RESOLVE_DIR/../.." && pwd)"

# resolve_persona depends on yaml_get (manifest-validation.sh), error (helpers.sh),
# the template accessors (template.sh), and find_persona (registry.sh). Each is
# sourced defensively so the lib is self-contained when loaded directly by a test.
if ! declare -F yaml_get >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/plugin-registry/manifest-validation.sh"
fi
if ! declare -F error >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/scripts/lib/helpers.sh"
fi
if ! declare -F template_stage_router_persona >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/pipeline/template.sh" 2>/dev/null || true
fi
if ! declare -F find_persona >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
fi

# ── _persona_find_in_root <id> <root> ────────────────────────────────────────
# Find a persona by id under a single plugins root. Returns the persona directory
# path on stdout; returns 1 if not found. Silent on absent/unreadable root.
_persona_find_in_root() {
    local persona_id="$1" plugins_root="$2"
    [[ -d "$plugins_root" ]] || return 1
    if ! declare -F find_persona >/dev/null 2>&1; then return 1; fi
    local mf
    mf="$(find_persona "$persona_id" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$mf" ]] || return 1
    printf '%s\n' "$(dirname "$mf")"
    return 0
}

# ── resolve_persona <stage_id> ───────────────────────────────────────────────
resolve_persona() {
    local stage_id="${1:-}"

    # 1. Env ZBUILD_<STAGE>_PERSONA wins (stage_id uppercased, '-'→'_').
    local _env_name
    _env_name="ZBUILD_$(printf '%s' "$stage_id" | tr '[:lower:]-' '[:upper:]_')_PERSONA"
    local persona_id="${!_env_name:-}"

    # 2. Template per-stage binding (template_stage_router_persona, ADR-051 §5).
    if [[ -z "$persona_id" ]] && declare -F template_stage_router_persona >/dev/null 2>&1; then
        local _tpl_stage="${ZBUILD_CURRENT_STAGE:-${stage_id}}"
        if [[ -n "$_tpl_stage" ]]; then
            persona_id="$(template_stage_router_persona "$_tpl_stage" 2>/dev/null || true)"
        fi
    fi

    # 3. Template global default (template_config_persona, ADR-051 §5).
    if [[ -z "$persona_id" ]] && declare -F template_config_persona >/dev/null 2>&1; then
        persona_id="$(template_config_persona 2>/dev/null || true)"
    fi

    # 4. Fall through to id=generic — the terminal fallback.
    [[ -z "$persona_id" ]] && persona_id="generic"

    # ── Two-root discovery ────────────────────────────────────────────────────
    # Installed root: ZBUILD_PLUGINS_ROOT (operator-set) or repo default.
    local _installed_root="${ZBUILD_PLUGINS_ROOT:-$_PERSONA_RESOLVE_ROOT/plugins}"

    # Repo overlay root: derived from ZBUILD_REPO_ROOT or git. NEVER assigned to
    # ZBUILD_PLUGINS_ROOT — ADR-024 hermeticity. Local variable only.
    local _repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    local _overlay_root=""
    [[ -n "$_repo_root" ]] && _overlay_root="$_repo_root/.zbuild/plugins"

    # Scan installed then overlay; overlay wins for same id.
    local _installed_dir="" _overlay_dir=""
    _installed_dir="$(_persona_find_in_root "$persona_id" "$_installed_root" 2>/dev/null || true)"
    if [[ -n "$_overlay_root" ]]; then
        _overlay_dir="$(_persona_find_in_root "$persona_id" "$_overlay_root" 2>/dev/null || true)"
    fi

    local persona_dir=""
    if [[ -n "$_overlay_dir" ]]; then
        persona_dir="$_overlay_dir"
    elif [[ -n "$_installed_dir" ]]; then
        persona_dir="$_installed_dir"
    fi

    # Not found in either root and not already the generic fallback: retry with generic.
    if [[ -z "$persona_dir" && "$persona_id" != "generic" ]]; then
        _installed_dir="$(_persona_find_in_root "generic" "$_installed_root" 2>/dev/null || true)"
        if [[ -n "$_overlay_root" ]]; then
            _overlay_dir="$(_persona_find_in_root "generic" "$_overlay_root" 2>/dev/null || true)"
        fi
        if [[ -n "$_overlay_dir" ]]; then
            persona_dir="$_overlay_dir"
        elif [[ -n "$_installed_dir" ]]; then
            persona_dir="$_installed_dir"
        fi
    fi

    [[ -n "$persona_dir" ]] || return 1
    printf '%s\n' "$persona_dir"
    return 0
}

# ── persona_text <persona_dir> ───────────────────────────────────────────────
# Read persona.perspective from the manifest; returns 0 always (empty is valid).
persona_text() {
    local persona_dir="${1:-}"
    [[ -z "$persona_dir" ]] && return 0
    local manifest="$persona_dir/manifest.yaml"
    [[ -f "$manifest" ]] || return 0
    if declare -F yaml_get >/dev/null 2>&1; then
        local perspective
        perspective="$(yaml_get "$manifest" "persona.perspective" 2>/dev/null || true)"
        printf '%s\n' "$perspective"
    fi
    return 0
}
