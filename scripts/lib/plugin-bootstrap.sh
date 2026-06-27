#!/usr/bin/env bash
# scripts/lib/plugin-bootstrap.sh — Shared plugin preamble helper (issue #381)
#
# Provides zbuild_plugin_bootstrap, a single call that every plugin.sh can make
# after its own load guard to:
#   1. Resolve the absolute plugin directory from BASH_SOURCE[0].
#   2. Walk up three levels to find the repo root
#      (all standard plugins live at plugins/<category>/<name>/plugin.sh).
#   3. Source scripts/lib/helpers.sh from the repo root.
#
# Usage (in a plugin.sh, AFTER the load guard):
#
#   [[ -n "${_ZBUILD_MY_PLUGIN_LOADED:-}" ]] && return 0
#   _ZBUILD_MY_PLUGIN_LOADED=1
#
#   # shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
#   zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
#   # _ZBUILD_PLUGIN_DIR  → absolute path to the plugin's own directory
#   # _ZBUILD_PLUGIN_ROOT → absolute path to the repo root
#
# After the call, plugins that source additional libs (event-bus, router, etc.)
# should do so using _ZBUILD_PLUGIN_ROOT as the base, and may assign the shared
# vars to plugin-specific aliases for clarity:
#
#   _MY_DIR="$_ZBUILD_PLUGIN_DIR"
#   _MY_ROOT="$_ZBUILD_PLUGIN_ROOT"
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_PLUGIN_BOOTSTRAP_LOADED:-}" ]] && return 0
_ZBUILD_PLUGIN_BOOTSTRAP_LOADED=1

# ─── zbuild_plugin_bootstrap ─────────────────────────────────────────────────
# Args:
#   $1 — the calling plugin's BASH_SOURCE[0] value
#
# Exports (as shell variables, not env exports):
#   _ZBUILD_PLUGIN_DIR  — absolute path of the directory containing plugin.sh
#   _ZBUILD_PLUGIN_ROOT — absolute path of the repo root (3 levels above plugin dir)
#
# Also sources scripts/lib/helpers.sh so plugins need not repeat that line.
#
# Returns 0 on success; 1 on any error (empty arg, cannot resolve dir/root,
# helpers.sh missing, or helpers.sh fails to source), printing diagnostics to stderr.
zbuild_plugin_bootstrap() {
    local plugin_source="${1:-}"

    if [[ -z "$plugin_source" ]]; then
        printf 'plugin-bootstrap: zbuild_plugin_bootstrap requires BASH_SOURCE[0] as first arg\n' >&2
        return 1
    fi

    # Resolve the plugin directory (absolute, symlink-safe).
    local _pdir
    _pdir="$(cd "$(dirname "$plugin_source")" && pwd)" || {
        printf 'plugin-bootstrap: cannot resolve plugin dir from: %s\n' "$plugin_source" >&2
        return 1
    }

    # Walk three levels up: plugins/<category>/<name>/ → repo root.
    local _proot
    _proot="$(cd "$_pdir/../../.." && pwd)" || {
        printf 'plugin-bootstrap: cannot resolve repo root from: %s\n' "$_pdir" >&2
        return 1
    }

    # Sanity check: helpers.sh must exist at the expected location.
    local _helpers="$_proot/scripts/lib/helpers.sh"
    if [[ ! -f "$_helpers" ]]; then
        printf 'plugin-bootstrap: helpers.sh not found at expected path: %s\n' "$_helpers" >&2
        printf 'plugin-bootstrap: is the plugin exactly 3 directory levels inside the repo root?\n' >&2
        return 1
    fi

    # Publish resolved paths for the caller.
    _ZBUILD_PLUGIN_DIR="$_pdir"
    _ZBUILD_PLUGIN_ROOT="$_proot"
    # #963: directory the read-only acceptance-grammar libs are sourced from.
    # Defaults to this engine's own scripts/lib (normal runs unchanged); a
    # self-host dogfood sets ZBUILD_CONTRACT_LIB_DIR to a working-tree snapshot
    # so contract-reader stages parse the dogfood's OWN grammar (ADR-023).
    _ZBUILD_CONTRACT_LIB_DIR="${ZBUILD_CONTRACT_LIB_DIR:-$_proot/scripts/lib}"

    # shellcheck source=./helpers.sh
    source "$_helpers" || {
        printf 'plugin-bootstrap: failed to source helpers.sh: %s\n' "$_helpers" >&2
        return 1
    }

    # Best-effort source artifact-render.sh so plugins inherit the renderer
    # registry without each having to source it explicitly. ADR-018.
    local _render="$_proot/scripts/lib/artifact-render.sh"
    if [[ -f "$_render" ]]; then
        # shellcheck source=./artifact-render.sh
        source "$_render" || true
    fi

    return 0
}
