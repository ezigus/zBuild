#!/usr/bin/env bash
# core/pipeline/dispatch.sh — plugin dispatch helpers extracted from runner.sh
# (issue #279). Resolves stage name → plugin directory via the registry.
# No behavior change from the original runner-embedded version.

[[ -n "${_ZBUILD_DISPATCH_LOADED:-}" ]] && return 0
_ZBUILD_DISPATCH_LOADED=1

_ZBUILD_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_DISPATCH_ROOT="$(cd "$_ZBUILD_DISPATCH_DIR/../.." && pwd)"

# Depends on yaml_get and discover_plugins — both in
# core/plugin-registry/registry.sh. Re-source defensively if either is
# absent so the file is self-contained when tests source dispatch.sh
# directly. (Copilot caught on #280: yaml_get is NOT in helpers.sh.)
if ! declare -F yaml_get >/dev/null 2>&1 || ! declare -F discover_plugins >/dev/null 2>&1; then
    source "$_ZBUILD_DISPATCH_ROOT/core/plugin-registry/registry.sh"
fi

# _find_plugin_for_stage <stage> [plugins_root]
# Returns plugin directory path on stdout, exit 1 if no matching plugin found.
_find_plugin_for_stage() {
    local stage="$1" plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_DISPATCH_ROOT/plugins}}" plugin_dir id
    while IFS= read -r plugin_dir; do
        id="$(yaml_get "$plugin_dir/manifest.yaml" "id")"
        [[ "$id" == "$stage" ]] && { echo "$plugin_dir"; return 0; }
    done < <(discover_plugins "$plugins_root" 2>/dev/null)
    return 1
}
