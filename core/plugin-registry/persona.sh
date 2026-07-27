#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — kind:persona resolver + stage/lens composition seam     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# A persona (kind:persona, #1304) is DATA: a professional identity (`role`) plus
# the mindset it brings (`perspective`). Stages and review lenses resolve a
# persona by id and compose it into their prompt framing. When no persona
# manifest is found, the resolver signals absence (returns 1, prints nothing) so
# the caller keeps its own existing hardcoded framing — a byte-identical
# fallback. Personas name a profession, never a technology (target-agnostic;
# repo-specific specialization is a separate seam).
#
# Depends on discover_plugins / yaml_get from the sibling registry modules, so
# it is sourced after discovery.sh in the registry.sh facade.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_PERSONA_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_PERSONA_LOADED=1

# ─── _find_persona_in_root <id> <plugins_root> ──────────────────────────────
# Single-root scan: prints the manifest path; returns 1 when absent or unreadable.
_find_persona_in_root() {
    local want_id="$1" plugins_root="$2"
    [[ -d "$plugins_root" ]] || return 1
    local plugin_dir manifest kind pid
    while IFS= read -r plugin_dir; do
        manifest="$plugin_dir/manifest.yaml"
        [[ -f "$manifest" ]] || continue
        kind="$(yaml_get "$manifest" "kind" 2>/dev/null || true)"
        [[ "$kind" == "persona" ]] || continue
        pid="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
        if [[ "$pid" == "$want_id" ]]; then
            printf '%s\n' "$manifest"
            return 0
        fi
    done < <(discover_plugins "$plugins_root" 2>/dev/null || true)
    return 1
}

# ─── find_persona <id> [plugins_root] [overlay_root] ────────────────────────
# Prints the manifest path of the kind:persona plugin with the given id.
# When overlay_root is provided, it is scanned after plugins_root; if the same
# id is found in the overlay, the overlay manifest wins (ADR-051 §4, #1305).
# Returns 1 if no such persona is discoverable in either root.
find_persona() {
    local want_id="$1"
    local plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT}/plugins}}"
    local overlay_root="${3:-}"
    [[ -z "$want_id" ]] && return 1
    local _inst_mf="" _ovr_mf=""
    _inst_mf="$(_find_persona_in_root "$want_id" "$plugins_root" 2>/dev/null || true)"
    if [[ -n "$overlay_root" ]]; then
        _ovr_mf="$(_find_persona_in_root "$want_id" "$overlay_root" 2>/dev/null || true)"
    fi
    if [[ -n "$_ovr_mf" ]]; then printf '%s\n' "$_ovr_mf"; return 0; fi
    if [[ -n "$_inst_mf" ]]; then printf '%s\n' "$_inst_mf"; return 0; fi
    return 1
}

# ─── resolve_persona_role <id> [plugins_root] ───────────────────────────────
# Prints the persona's role. Returns 1 if the persona is absent.
resolve_persona_role() {
    local manifest; manifest="$(find_persona "$1" "${2:-}")" || return 1
    yaml_get "$manifest" "persona.role"
}

# ─── resolve_persona_perspective <id> [plugins_root] ────────────────────────
# Prints the persona's perspective (may be empty — RECOMMENDED, not required).
# Returns 1 only when the persona itself is absent.
resolve_persona_perspective() {
    local manifest; manifest="$(find_persona "$1" "${2:-}")" || return 1
    yaml_get "$manifest" "persona.perspective"
}

# ─── resolve_persona_charter <id> [plugins_root] ─────────────────────────────
# Prints the persona's charter text (the perspective field). Returns 1 (prints
# nothing) when the persona is absent — same absence-signal contract as siblings.
# Delegates to resolve_persona_perspective: persona.perspective is the lens-specific
# examination directive, used as the charter text when driving _rl_lens_charter.
resolve_persona_charter() {
    resolve_persona_perspective "$@"
}

# ─── persona_stage_framing <id> <task> [plugins_root] ───────────────────────
# Stage seam: "{perspective}\n\n{task}" — perspective-first output (behavior, not
# profession; #1569). persona.perspective is REQUIRED at manifest-validation time,
# so for a valid persona this always emits behavior + task. Returns 1 (prints
# nothing) when the persona is ABSENT; the empty-perspective guard below is a
# defensive backstop, treated the same as absent so the caller keeps its own
# framing rather than injecting an identity-less prompt. (role is manifest data —
# resolvable via resolve_persona_role — but is deliberately NOT in this output.)
# Callers must export ZBUILD_STAGE_IO_PERSONA=<id> (rc=0) or <id>:fallback (rc=1)
# before calling stage_io_begin (or route_to_model, which calls it internally).
persona_stage_framing() {
    local id="$1" task="$2" root="${3:-}"
    local manifest; manifest="$(find_persona "$id" "$root")" || return 1
    local perspective; perspective="$(yaml_get "$manifest" "persona.perspective")"
    [[ -n "$perspective" ]] || return 1
    printf '%s\n\n%s' "$perspective" "$task"
}
