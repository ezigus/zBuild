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
#     ADR-051 §4 amendment (#1621) — installed-wins-for-pinned-ids:
#       When the id was resolved from the template (steps 2/3), the installed root
#       wins if it has the id; the overlay only provides ids absent from installed
#       (overlay-extends, not overlay-substitutes). For env-override ids (step 1),
#       the overlay still wins (operator's explicit choice). Whenever an overlay
#       persona is used (accepted or blocked), a persona.overlay.used audit event
#       is emitted with fields: stage_id, persona_id, overlay_path, blocked.
#     ZBUILD_REPO_ROOT is validated before use: must be non-empty, start with /,
#     and contain no .. path components. An invalid value silently yields no overlay.
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
# find_persona (registry.sh), and the template persona accessors (template.sh).
# Each is sourced defensively so the lib is self-contained when loaded directly by a test.
if ! declare -F yaml_get >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/plugin-registry/manifest-validation.sh"
fi
if ! declare -F error >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/scripts/lib/helpers.sh"
fi
if ! declare -F find_persona >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
fi
if ! declare -F template_stage_router_persona >/dev/null 2>&1; then
    source "$_PERSONA_RESOLVE_ROOT/core/pipeline/template.sh" 2>/dev/null || true
fi

# ── resolve_persona <stage_id> ───────────────────────────────────────────────
resolve_persona() {
    local stage_id="${1:-}"

    # ONE stage identity for the whole chain. Previously step 1 keyed off the
    # caller's stage_id while step 2 preferred ZBUILD_CURRENT_STAGE, so
    # `resolve_persona build` under `ZBUILD_CURRENT_STAGE=design` read the env
    # override for build but the template binding for design — two stages in one
    # resolution. The orchestrator does export ZBUILD_CURRENT_STAGE per member
    # (core/pipeline/parallel-orchestrator.sh:146), so it is a sound *fallback*
    # when the caller passes no stage, but never an override of an explicit one.
    local _stage="${stage_id:-${ZBUILD_CURRENT_STAGE:-}}"

    # Track which precedence step resolved the id (env/template/config/generic).
    # Used to implement installed-wins-for-pinned-ids (ADR-051 §4, #1621).
    local _persona_id_source="generic"

    # 1. Env ZBUILD_<STAGE>_PERSONA wins (stage uppercased, '-'→'_').
    local _env_name
    _env_name="ZBUILD_$(printf '%s' "$_stage" | tr '[:lower:]-' '[:upper:]_')_PERSONA"
    local persona_id="${!_env_name:-}"
    [[ -n "$persona_id" ]] && _persona_id_source="env"

    # 2. Template per-stage binding (template_stage_router_persona, ADR-051 §5).
    if [[ -z "$persona_id" ]] && declare -F template_stage_router_persona >/dev/null 2>&1; then
        if [[ -n "$_stage" ]]; then
            persona_id="$(template_stage_router_persona "$_stage" 2>/dev/null || true)"
            [[ -n "$persona_id" ]] && _persona_id_source="template"
        fi
    fi

    # 3. Template global default (template_config_persona, ADR-051 §5).
    if [[ -z "$persona_id" ]] && declare -F template_config_persona >/dev/null 2>&1; then
        persona_id="$(template_config_persona 2>/dev/null || true)"
        [[ -n "$persona_id" ]] && _persona_id_source="config"
    fi

    # 4. Fall through to id=generic — the terminal fallback.
    [[ -z "$persona_id" ]] && persona_id="generic"

    # ── Two-root discovery (ADR-051 §4, ADR-024 hermeticity) ─────────────────
    # Installed root: ZBUILD_PLUGINS_ROOT (operator-set) or repo default.
    local _installed_root="${ZBUILD_PLUGINS_ROOT:-$_PERSONA_RESOLVE_ROOT/plugins}"

    # Overlay root: derived from ZBUILD_REPO_ROOT or git — NEVER from
    # ZBUILD_PLUGINS_ROOT (ADR-024: overlay root must stay a local variable).
    # ZBUILD_REPO_ROOT validation (#1621): must be non-empty, start with '/',
    # and contain no '..' path components. Invalid value → no overlay (fail-open).
    local _repo_root_raw="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    local _repo_root=""
    if [[ -n "$_repo_root_raw" && "$_repo_root_raw" == /* ]] && \
       [[ "$_repo_root_raw" != *"/../"* && "$_repo_root_raw" != *"/.." && "$_repo_root_raw" != "../"* ]]; then
        _repo_root="$_repo_root_raw"
    fi
    local _overlay_root=""
    [[ -n "$_repo_root" ]] && _overlay_root="$_repo_root/.zbuild/plugins"

    # ── installed-wins-for-pinned-ids (ADR-051 §4 amendment, #1621) ──────────
    # For template-pinned ids (source=template or config), the installed root wins
    # if it has the id: the overlay may only supply ids absent from the installed
    # tree. For env-override ids (source=env), the overlay is still accepted.
    local _found_mf=""
    local _overlay_used=0
    local _overlay_blocked=0

    if [[ "$_persona_id_source" == "template" || "$_persona_id_source" == "config" ]]; then
        # Installed-wins path: check installed first; accept overlay only if not found there.
        local _inst_mf=""
        _inst_mf="$(_find_persona_in_root "$persona_id" "$_installed_root" 2>/dev/null || true)"
        if [[ -n "$_inst_mf" ]]; then
            _found_mf="$_inst_mf"
            # Check if overlay also has this id (for audit event).
            if [[ -n "$_overlay_root" ]]; then
                local _ovr_check=""
                _ovr_check="$(_find_persona_in_root "$persona_id" "$_overlay_root" 2>/dev/null || true)"
                if [[ -n "$_ovr_check" ]]; then
                    _overlay_blocked=1
                fi
            fi
        else
            # Not in installed: check overlay (additive persona).
            if [[ -n "$_overlay_root" ]]; then
                local _ovr_mf=""
                _ovr_mf="$(_find_persona_in_root "$persona_id" "$_overlay_root" 2>/dev/null || true)"
                if [[ -n "$_ovr_mf" ]]; then
                    _found_mf="$_ovr_mf"
                    _overlay_used=1
                fi
            fi
            # If still not found, fall back to installed generic later.
            [[ -z "$_found_mf" ]] && _found_mf="$(_find_persona_in_root "$persona_id" "$_installed_root" 2>/dev/null || true)"
        fi
    else
        # Env-override or generic-fallback: overlay wins on same id (original behavior).
        _found_mf="$(find_persona "$persona_id" "$_installed_root" "$_overlay_root" 2>/dev/null || true)"
        # Detect if the overlay was the winner for audit event.
        if [[ -n "$_overlay_root" && -n "$_found_mf" ]]; then
            local _ovr_check2=""
            _ovr_check2="$(_find_persona_in_root "$persona_id" "$_overlay_root" 2>/dev/null || true)"
            [[ -n "$_ovr_check2" && "$_found_mf" == "$_ovr_check2" ]] && _overlay_used=1
        fi
    fi

    # Emit audit event when overlay activity occurred (accepted or blocked, #1621).
    if [[ -n "$_overlay_root" && ( "$_overlay_used" -eq 1 || "$_overlay_blocked" -eq 1 ) ]]; then
        if declare -F eb_emit_event >/dev/null 2>&1; then
            eb_emit_event "persona.overlay.used" \
                "stage_id=$_stage" \
                "persona_id=$persona_id" \
                "overlay_path=$_overlay_root" \
                "blocked=$_overlay_blocked" 2>/dev/null || true
        fi
    fi

    local persona_dir=""
    [[ -n "$_found_mf" ]] && persona_dir="$(dirname "$_found_mf")"

    # Not found in either root: retry with the generic terminal fallback.
    if [[ -z "$persona_dir" && "$persona_id" != "generic" ]]; then
        _found_mf="$(find_persona "generic" "$_installed_root" "$_overlay_root" 2>/dev/null || true)"
        [[ -n "$_found_mf" ]] && persona_dir="$(dirname "$_found_mf")"
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
