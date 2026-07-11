#!/usr/bin/env bash
# scripts/lib/tier-resolve.sh — resolve a plugin's model tier from the SINGLE
# source of truth: the plugin's own manifest config.tier_default (#1231, ADR-003).
#
# Why this exists: agent plugins used to hardcode `${ZBUILD_<ID>_TIER:-Tn}`,
# duplicating the tier value that already lives in the manifest. That literal
# drifted from the manifest (#960/#1230: impact declared T2 in its manifest but
# kept T1 in code → silent router timeout, rc=124). This resolver makes the
# manifest config.tier_default the ONLY per-plugin tier declaration; the
# operator override ZBUILD_<ID>_TIER still wins. Plug-and-play: no central
# stage→tier map — each plugin declares its own tier in its own manifest, so a
# new routing plugin plugs in with zero engine edits.
#
# Public function:
#   resolve_tier <plugin_id> <plugin_dir>
#     1. If ZBUILD_<ID>_TIER is set (ID = plugin_id uppercased, '-'→'_';
#        e.g. review-lens → ZBUILD_REVIEW_LENS_TIER), that value wins.
#     2. Else, if a template is loaded and ZBUILD_CURRENT_STAGE is set, the
#        template's per-stage router.tier OVERRIDE for that stage (#1252,
#        ADR-017 §8) — a per-repo tier ordinal pinned in the template.
#     3. Else read config.tier_default from <plugin_dir>/manifest.yaml.
#     4. Else fail loud (a routing plugin with no declared tier is a bug).
#     Precedence: env ZBUILD_<ID>_TIER > template router.tier > manifest default.
#     The result must match ^T[0-4]$ or resolve_tier fails loud.
#     Prints the resolved tier to stdout; returns 0 on success, non-zero on error.
#
# Sourced library: no set -euo pipefail (would mutate the caller's shell options).

[[ -n "${_ZBUILD_TIER_RESOLVE_LOADED:-}" ]] && return 0
_ZBUILD_TIER_RESOLVE_LOADED=1

_TIER_RESOLVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TIER_RESOLVE_ROOT="$(cd "$_TIER_RESOLVE_DIR/../.." && pwd)"

# resolve_tier depends on yaml_get (core/plugin-registry/manifest-validation.sh)
# and error (scripts/lib/helpers.sh). Source each defensively so the lib is
# self-contained whether loaded via core/router/route.sh or directly by a test.
if ! declare -F yaml_get >/dev/null 2>&1; then
    source "$_TIER_RESOLVE_ROOT/core/plugin-registry/manifest-validation.sh"
fi
if ! declare -F error >/dev/null 2>&1; then
    source "$_TIER_RESOLVE_ROOT/scripts/lib/helpers.sh"
fi
# #1252: the template router.tier source needs template_stage_router_tier. Plugin
# subprocesses source route.sh (→ this lib) but NOT template.sh, and a shell
# function does not cross the `bash <plugin>` process boundary — so without this
# the template override would be silently inert (green-but-inert). Source
# template.sh defensively (best-effort; the load guard makes a repeat a no-op).
# resolve_tier ALSO guards the call with `command -v`, so if this source is
# unavailable the resolver still degrades to the manifest default, never errors.
if ! declare -F template_stage_router_tier >/dev/null 2>&1; then
    source "$_TIER_RESOLVE_ROOT/core/pipeline/template.sh" 2>/dev/null || true
fi

resolve_tier() {
    local plugin_id="${1:-}" plugin_dir="${2:-}"
    if [[ -z "$plugin_id" || -z "$plugin_dir" ]]; then
        error "resolve_tier requires <plugin_id> <plugin_dir>"
        return 1
    fi

    # 1. Operator override wins: ZBUILD_<ID>_TIER (ID uppercased, '-'→'_').
    local env_name
    env_name="ZBUILD_$(printf '%s' "$plugin_id" | tr '[:lower:]-' '[:upper:]_')_TIER"
    local tier="${!env_name:-}"

    # 2. Else the TEMPLATE's per-stage router.tier override (#1252, ADR-017 §8).
    #    A per-repo template can pin a tier ORDINAL for one stage, keyed by
    #    ZBUILD_CURRENT_STAGE (exported on every dispatch path). This sits BETWEEN
    #    the env override and the manifest default so the manifest stays the
    #    fail-loud default while a template can raise/lower a specific stage.
    #    Guarded: if template.sh's accessor isn't loaded, degrade to the manifest
    #    (never error) — the resolver must stay usable when a test sources only
    #    tier-resolve.sh. The accessor validates ^T[0-4]$ at read time and fails
    #    loud on a bad template value; propagate that failure.
    if [[ -z "$tier" && -n "${ZBUILD_CURRENT_STAGE:-}" ]] \
       && command -v template_stage_router_tier >/dev/null 2>&1; then
        local tpl_tier
        if ! tpl_tier="$(template_stage_router_tier "$ZBUILD_CURRENT_STAGE")"; then
            error "resolve_tier: invalid template router.tier for stage '$ZBUILD_CURRENT_STAGE'"
            return 1
        fi
        [[ -n "$tpl_tier" ]] && tier="$tpl_tier"
    fi

    # 3. Else the manifest's config.tier_default (single source of truth).
    if [[ -z "$tier" ]]; then
        local manifest="$plugin_dir/manifest.yaml"
        if [[ ! -f "$manifest" ]]; then
            error "resolve_tier: manifest not found for '$plugin_id': $manifest"
            return 1
        fi
        tier="$(yaml_get "$manifest" "config.tier_default" 2>/dev/null || true)"
    fi

    # 4. Fail loud: a routing plugin with no declared tier is a bug, not a
    #    silent default (matches the project's fail-loud-preflight convention).
    if [[ -z "$tier" ]]; then
        error "resolve_tier: no tier for '$plugin_id' — declare config.tier_default in $plugin_dir/manifest.yaml (or set $env_name)"
        return 1
    fi
    if [[ ! "$tier" =~ ^T[0-4]$ ]]; then
        error "resolve_tier: invalid tier '$tier' for '$plugin_id' — must be T0-T4"
        return 1
    fi

    printf '%s\n' "$tier"
    return 0
}
