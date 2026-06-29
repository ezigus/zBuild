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

# resolve_stage_plugin <stage> [plugins_root]
# ADR-042: uniform stage→plugin resolution. Adopted by the cycle and parallel
# dispatch paths (runner.sh) to match the leaf path's pre-existing role-then-id
# rule (the leaf path keeps its own inline logic). A stage's flow-name need not
# equal its plugin `id` — role binding (ADR-001) is resolved FIRST, with id-match
# as the backward-compat fallback. Cycle and parallel members previously used
# id-only and so silently failed to resolve role-bound stages whose plugin id ≠
# stage name (e.g. lint→lint-gate, lens-*→review-lens).
# Single-plugin resolution (cycle/parallel members do NOT fan out): first match
# wins. Side-effect-free: echoes the plugin dir and returns 0 on hit, returns 1
# if nothing resolves. (The resolver's best-effort registry.role-unresolved
# diagnostic on a role miss is the same as every other strategy path.)
resolve_stage_plugin() {
    local stage="$1" plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_DISPATCH_ROOT/plugins}}"
    local roles role platform plugin_dir
    # Role-then-id: try declared roles first (when template data + resolver present).
    if declare -F template_stage_roles >/dev/null 2>&1 && declare -F resolve_plugin_for_role >/dev/null 2>&1; then
        roles="$(template_stage_roles "$stage" 2>/dev/null || true)"
        if [[ -n "$roles" ]]; then
            # Mirror fanout.sh ~41-43: platform-specific then generic. Use the
            # caller's detected platforms (dynamic scope from runner) when set;
            # the resolver itself falls back to generic plugins within one call.
            local -a _platforms=()
            if declare -p _DETECTED_PLATFORMS >/dev/null 2>&1 && [[ ${#_DETECTED_PLATFORMS[@]} -gt 0 ]]; then
                _platforms=("${_DETECTED_PLATFORMS[@]}")
            fi
            while IFS= read -r role; do
                [[ -z "$role" ]] && continue
                for platform in "${_platforms[@]+"${_platforms[@]}"}"; do
                    plugin_dir="$(resolve_plugin_for_role "$role" "$platform" "$plugins_root" 2>/dev/null || true)"
                    [[ -n "$plugin_dir" ]] && { echo "$plugin_dir"; return 0; }
                done
                plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
                [[ -n "$plugin_dir" ]] && { echo "$plugin_dir"; return 0; }
            done <<< "$roles"
        fi
    fi
    # Fallback: backward-compat id match (stage name == manifest id).
    plugin_dir="$(_find_plugin_for_stage "$stage" "$plugins_root" 2>/dev/null || true)"
    [[ -n "$plugin_dir" ]] && { echo "$plugin_dir"; return 0; }
    return 1
}
