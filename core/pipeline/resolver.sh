#!/usr/bin/env bash
# core/pipeline/resolver.sh — Role-based plugin resolver (issue #208)
# ADR-009 (platform-aware modularity)
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_RESOLVER_LOADED:-}" ]] && return 0
_ZBUILD_RESOLVER_LOADED=1

_ZBUILD_RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_RESOLVER_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../plugin-registry/registry.sh
source "$_ZBUILD_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_ZBUILD_ROOT/core/event-bus/event-bus.sh"

# ─── _semver_gt — returns 0 if a > b, 1 otherwise ───────────────────────────
# Pure bash semver comparison; avoids sort -V which is absent on macOS BSD sort.
_semver_gt() {
    local a="$1" b="$2"
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$a"
    IFS=. read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [[ $a1 -gt $b1 ]] && return 0
    [[ $a1 -eq $b1 && $a2 -gt $b2 ]] && return 0
    [[ $a1 -eq $b1 && $a2 -eq $b2 && $a3 -gt $b3 ]] && return 0
    return 1
}

# ─── _resolver_pick_best — select highest-version (then alpha-id) candidate ──
# Input: one or more "version|id|dir" entries as separate arguments.
# Output: the winning plugin_dir path on stdout.
_resolver_pick_best() {
    local best_version="" best_id="" best_dir=""
    for entry in "$@"; do
        IFS='|' read -r version id dir <<< "$entry"
        if [[ -z "$best_version" ]]; then
            best_version="$version"; best_id="$id"; best_dir="$dir"
        elif _semver_gt "$version" "$best_version"; then
            best_version="$version"; best_id="$id"; best_dir="$dir"
        elif [[ "$version" == "$best_version" && "$id" < "$best_id" ]]; then
            best_id="$id"; best_dir="$dir"
        fi
    done
    echo "$best_dir"
}

# ─── resolve_plugin_for_role — main entry point ──────────────────────────────
# Usage: resolve_plugin_for_role <role> [platform] [plugins_root]
#
# Pass 1: exact platform match AND role match.
# Pass 2: role match with no/null/absent platform (generic fallback).
# Tie-break: highest semver wins; alphabetically-first id breaks ties.
# No match: emits registry.role-unresolved event (best-effort) and returns 1.
# Match:    prints plugin_dir and returns 0.
resolve_plugin_for_role() {
    local role="$1"
    local platform="${2:-}"
    local plugins_root="${3:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}}"

    local candidates_platform=()
    local candidates_generic=()

    while IFS= read -r plugin_dir; do
        local manifest="$plugin_dir/manifest.yaml"
        local plugin_role plugin_platform plugin_version plugin_id
        plugin_role="$(yaml_get "$manifest" "provides.role")"
        [[ "$plugin_role" != "$role" ]] && continue

        plugin_platform="$(yaml_get "$manifest" "platform")"
        plugin_version="$(yaml_get "$manifest" "version")"
        plugin_id="$(yaml_get "$manifest" "id")"

        if [[ -n "$platform" && "$plugin_platform" == "$platform" ]]; then
            candidates_platform+=("$plugin_version|$plugin_id|$plugin_dir")
        elif [[ -z "$plugin_platform" || "$plugin_platform" == "null" ]]; then
            candidates_generic+=("$plugin_version|$plugin_id|$plugin_dir")
        fi
    done < <(discover_plugins "$plugins_root" 2>/dev/null)

    local result=""
    if [[ ${#candidates_platform[@]} -gt 0 ]]; then
        result="$(_resolver_pick_best "${candidates_platform[@]}")"
    elif [[ ${#candidates_generic[@]} -gt 0 ]]; then
        result="$(_resolver_pick_best "${candidates_generic[@]}")"
    else
        eb_emit_event "registry.role-unresolved" "role=$role" "platform=${platform:-generic}" 2>/dev/null || true
        return 1
    fi

    echo "$result"
}
