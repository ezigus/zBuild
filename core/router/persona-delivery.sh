#!/usr/bin/env bash
# core/router/persona-delivery.sh — every model call a dispatched stage makes
# runs as that stage's persona (ADR-051, amended 2026-10-12).
#
# The persona is found the way ADR-051 §4/§5 says (resolve_persona: the
# ZBUILD_<STAGE>_PERSONA override, the stage's template pin, the template's
# default, generic; the target repository's .zbuild/plugins/persona/<id> before
# the install's). A map element runs as the persona the template names for it,
# never one guessed from its name. No stage frames a persona.
#
# How the persona reaches the model is the provider's: a provider module that
# defines provider_<name>_persona_args gives the call's arguments (Anthropic:
# --agents <json> --agent <id>). One that cannot gets the persona as the
# prompt's first section, "## Who you are", added before redaction. Either way
# the persona's text passes through the scope redaction (ADR-051 §6).
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_ROUTE_PERSONA_LOADED:-}" ]] && return 0
_ZBUILD_ROUTE_PERSONA_LOADED=1

_ZB_PERSONA_SECTION='## Who you are'
_ROUTE_PERSONA_KEY="" _ROUTE_PERSONA_ID="" _ROUTE_PERSONA_TEXT="" _ROUTE_PERSONA_IN_PROMPT=0
_ROUTE_PERSONA_DESC="" _ROUTE_PERSONA_REDACTED=""
_ROUTE_PERSONA_ARGS=()

# _route_persona_prepare — for a call a dispatched stage makes, set
# _ROUTE_PERSONA_ID / _TEXT and either _ROUTE_PERSONA_ARGS (the provider takes
# it) or _ROUTE_PERSONA_IN_PROMPT=1 (it goes in the prompt). Nothing for a call
# outside a stage. Worked out once per stage and element.
_route_persona_prepare() {
    local key="${ZBUILD_PLUGIN_DIR:-}|${ZBUILD_CURRENT_STAGE:-}|${ZBUILD_MAP_ELEMENT:-}|${_ROUTE_PROVIDER:-anthropic}"
    [[ "$key" == "$_ROUTE_PERSONA_KEY" ]] && return 0
    _ROUTE_PERSONA_KEY="$key" _ROUTE_PERSONA_ID="" _ROUTE_PERSONA_TEXT="" _ROUTE_PERSONA_IN_PROMPT=0
    _ROUTE_PERSONA_DESC="" _ROUTE_PERSONA_REDACTED=""
    _ROUTE_PERSONA_ARGS=()
    [[ -n "${ZBUILD_PLUGIN_DIR:-}" && -n "${ZBUILD_CURRENT_STAGE:-}" ]] || return 0
    local dir manifest desc p fn
    dir="$(resolve_persona "$ZBUILD_CURRENT_STAGE" 2>/dev/null)" || return 0
    manifest="$dir/manifest.yaml"
    [[ -f "$manifest" ]] || return 0
    yaml_get_v _ROUTE_PERSONA_ID "$manifest" id 2>/dev/null || true
    yaml_get_v _ROUTE_PERSONA_TEXT "$manifest" persona.perspective 2>/dev/null || true
    yaml_get_v desc "$manifest" summary 2>/dev/null || true
    [[ -n "$_ROUTE_PERSONA_ID" && -n "$_ROUTE_PERSONA_TEXT" ]] || { _ROUTE_PERSONA_ID=""; return 0; }
    export ZBUILD_STAGE_IO_PERSONA="$_ROUTE_PERSONA_ID"
    p="${_ROUTE_PROVIDER:-anthropic}"
    declare -F _route_provider_load >/dev/null 2>&1 && _route_provider_load "$p" >/dev/null 2>&1
    fn="provider_${p//-/_}_persona_args"
    _ROUTE_PERSONA_DESC="${desc:-$_ROUTE_PERSONA_ID}"
    if declare -F "$fn" >/dev/null 2>&1; then
        mapfile -t _ROUTE_PERSONA_ARGS < <("$fn" "$_ROUTE_PERSONA_ID" "$_ROUTE_PERSONA_DESC" "$_ROUTE_PERSONA_TEXT" 2>/dev/null)
    fi
    [[ ${#_ROUTE_PERSONA_ARGS[@]} -gt 0 ]] || _ROUTE_PERSONA_IN_PROMPT=1
    return 0
}

# _route_persona_redact <manifest> <allowlist> <cycle_id> — the persona given
# to the provider is model-bound text too: pass it through the scope redaction
# before the prompt's own pass (so that one stays last before the call). A
# persona that cannot be redacted is not sent.
_route_persona_redact() {
    local manifest="$1" allowlist="$2" cycle_id="$3" in out fn text=""
    [[ ${#_ROUTE_PERSONA_ARGS[@]} -gt 0 && "$_ROUTE_PERSONA_REDACTED" != "$_ROUTE_PERSONA_KEY" ]] || return 0
    [[ -n "$manifest" ]] || return 0
    declare -F apply_scope_redaction >/dev/null 2>&1 || { _ROUTE_PERSONA_ARGS=(); return 0; }
    in="$(mktemp 2>/dev/null)" && out="$(mktemp 2>/dev/null)" || { _ROUTE_PERSONA_ARGS=(); return 0; }
    printf '%s\n' "$_ROUTE_PERSONA_TEXT" > "$in"
    if apply_scope_redaction "$in" "$out" "$manifest" "$allowlist" "$cycle_id" >/dev/null 2>&1; then
        text="$(<"$out")"
    fi
    rm -f "${in:?}" "${out:?}"
    fn="provider_${_ROUTE_PROVIDER:-anthropic}_persona_args"; fn="${fn//-/_}"
    _ROUTE_PERSONA_ARGS=()
    if [[ -n "$text" ]] && declare -F "$fn" >/dev/null 2>&1; then
        _ROUTE_PERSONA_TEXT="$text"
        mapfile -t _ROUTE_PERSONA_ARGS < <("$fn" "$_ROUTE_PERSONA_ID" "$_ROUTE_PERSONA_DESC" "$text" 2>/dev/null)
    fi
    _ROUTE_PERSONA_REDACTED="$_ROUTE_PERSONA_KEY"
    return 0
}

# _route_persona_into_prompt <file> — for a provider that cannot take an agent,
# the persona as the prompt's first section. Run before redaction.
_route_persona_into_prompt() {
    local f="$1" tmp
    [[ "$_ROUTE_PERSONA_IN_PROMPT" == "1" && -n "$_ROUTE_PERSONA_TEXT" ]] || return 0
    [[ "$(head -n1 "$f" 2>/dev/null)" == "$_ZB_PERSONA_SECTION" ]] && return 0
    tmp="$f.persona.$$"
    { printf '%s\n\n%s\n\n' "$_ZB_PERSONA_SECTION" "$_ROUTE_PERSONA_TEXT"; cat "$f"; } > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}
