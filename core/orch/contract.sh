#!/usr/bin/env bash
# core/orch/contract.sh — Orchestrator backend contract layer (ADR-011, issue #219)
#
# Defines the orchestrator backend interface contract.  Strategy plugins
# (issues #198/#199/#200) source this file and provide implementations of
# the five contract functions.  The contract layer itself provides:
#
#   orch_has_capability <cap>   — queries the loaded backend's capabilities
#   orch_load_backend   <alias> — finds and sources a backend plugin by alias
#
# On file load, _orch_load_backend is called automatically to wire up the
# configured backend.  If no plugin is found, no-op stubs remain in place so
# callers can detect the "not implemented" state gracefully.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_ORCH_CONTRACT_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_CONTRACT_LOADED=1

# Sentinel: 0 = only stubs loaded, 1 = a real backend plugin was sourced.
# If any contract function is already defined when this file is sourced, a
# backend was pre-loaded (sourced before this contract file).  Mark it loaded
# so _orch_load_backend does not overwrite those implementations.
if declare -F orch_spawn >/dev/null 2>&1 || \
   declare -F orch_dispatch >/dev/null 2>&1 || \
   declare -F orch_capabilities >/dev/null 2>&1; then
    _ZBUILD_ORCH_BACKEND_LOADED=1
else
    _ZBUILD_ORCH_BACKEND_LOADED=0
fi

_ZBUILD_ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "${_ZBUILD_ORCH_DIR}/../.." && pwd)"

# ─── Scratch directory for pool state ───────────────────────────────────────
# #898: the default is computed at use-time in `_strategy_orch_scratch_dir`
# (core/pipeline/strategies/common.sh) so it can be re-rooted under the per-run
# state dir (~/.zbuild/state/runs/<run_id>/orch) once ZBUILD_RUN_ID is known —
# the orchestrator analog of #887/#889. An explicit ZBUILD_ORCH_SCRATCH still
# overrides. (Was: a flat ~/.zbuild/state/orch baked here at source time, before
# run_id existed, which made per-run isolation impossible.)

# ─── _orch_not_implemented ───────────────────────────────────────────────────
# Emits an event and returns 1. Used by contract stubs before a backend loads.
_orch_not_implemented() {
    local fn_name="$1"
    local context="${2:-(no pool)}"
    # Emit event if emit_event is available (event-bus may not be loaded yet)
    if declare -F emit_event >/dev/null 2>&1; then
        emit_event "orch.contract.not_implemented" "fn=${fn_name}" "context=${context}" || true
    fi
    warn "orch contract: ${fn_name} not implemented (context: ${context})" || true
    return 1
}

# ─── Contract stubs — overridden by backend source ──────────────────────────
# These are only defined if the backend has not already provided them.

if ! declare -F orch_spawn >/dev/null 2>&1; then
    orch_spawn()        { _orch_not_implemented "orch_spawn" "$1"; }
fi

if ! declare -F orch_dispatch >/dev/null 2>&1; then
    orch_dispatch()     { _orch_not_implemented "orch_dispatch" "$1"; }
fi

if ! declare -F orch_collect >/dev/null 2>&1; then
    # Exit code convention: 0=all pass, 1=all fail, 2=partial (some pass some fail).
    # Backends normalise work-unit exit codes — any non-zero counts as fail;
    # the original work-unit rc is NOT passed through.
    orch_collect()      { _orch_not_implemented "orch_collect" "$1"; }
fi

if ! declare -F orch_shutdown >/dev/null 2>&1; then
    orch_shutdown()     { _orch_not_implemented "orch_shutdown" "$1"; }
fi

if ! declare -F orch_capabilities >/dev/null 2>&1; then
    orch_capabilities() { _orch_not_implemented "orch_capabilities" "(no pool)"; }
fi

# ─── orch_has_capability ─────────────────────────────────────────────────────
# Queries the loaded backend's capability list.
# Usage: orch_has_capability <capability_name>
# Returns 0 if the capability is present in orch_capabilities output, 1 if not.
orch_has_capability() {
    local cap="$1"
    local caps
    caps="$(orch_capabilities 2>/dev/null)" || return 1
    if printf '%s' "$caps" | grep -qF "\"${cap}\""; then
        return 0
    fi
    return 1
}

# ─── _orch_find_backend_dir ──────────────────────────────────────────────────
# Lightweight backend plugin discovery that does NOT require the full registry.
# Scans $plugins_root for a plugin whose manifest declares:
#   provides.role: orchestrator-backend
#   AND (id: <alias> OR provides.alias: <alias>)
# Prints the plugin directory on success.  Returns 1 if not found.
_orch_find_backend_dir() {
    local alias="$1"
    local plugins_root="${2:-${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT}/plugins}}"

    [[ -d "$plugins_root" ]] || return 1

    local manifest plugin_dir
    while IFS= read -r manifest; do
        plugin_dir="$(dirname "$manifest")"
        # Check provides.role
        if ! grep -q 'role:.*orchestrator-backend' "$manifest" 2>/dev/null; then
            continue
        fi
        # Check id or provides.alias match
        local id declared_alias
        id="$(awk '/^id:/ { sub(/^id:[[:space:]]*/, ""); print; exit }' "$manifest" 2>/dev/null)"
        declared_alias="$(awk '/^[[:space:]]*alias:/ { sub(/^[[:space:]]*alias:[[:space:]]*/, ""); print; exit }' "$manifest" 2>/dev/null)"
        if [[ "$id" == "$alias" || "$declared_alias" == "$alias" ]]; then
            echo "$plugin_dir"
            return 0
        fi
    done < <(find "$plugins_root" -maxdepth 4 -name 'manifest.yaml' -type f 2>/dev/null)

    return 1
}

# ─── orch_load_backend ───────────────────────────────────────────────────────
# Finds and sources a backend plugin by its alias.
# Usage: orch_load_backend <alias>
# Uses find_plugin_for_role (if available) or lightweight _orch_find_backend_dir
# to locate the plugin, then sources plugin.sh.
# Falls back to the built-in orch-sequential plugin if the alias is "sequential".
# If no plugin is found, emits a warning and returns 1.
orch_load_backend() {
    local backend="${1:-}"
    local plugin_dir

    if [[ -z "$backend" ]]; then
        warn "orch_load_backend: no backend alias provided" || true
        return 1
    fi

    # Try registry lookup if find_plugin_for_role is available
    if declare -F find_plugin_for_role >/dev/null 2>&1; then
        plugin_dir="$(find_plugin_for_role "orchestrator-backend" "$backend" 2>/dev/null)" || plugin_dir=""
        if [[ -n "$plugin_dir" && -f "${plugin_dir}/plugin.sh" ]]; then
            # shellcheck disable=SC1090
            source "${plugin_dir}/plugin.sh"
            _ZBUILD_ORCH_BACKEND_LOADED=1
            return 0
        fi
    fi

    # Fallback: lightweight scan without the full registry
    plugin_dir="$(_orch_find_backend_dir "$backend" 2>/dev/null)" || plugin_dir=""
    if [[ -n "$plugin_dir" && -f "${plugin_dir}/plugin.sh" ]]; then
        # shellcheck disable=SC1090
        source "${plugin_dir}/plugin.sh"
        _ZBUILD_ORCH_BACKEND_LOADED=1
        return 0
    fi

    # Fallback: try built-in orch-sequential plugin by known path
    local sequential_sh="${_ZBUILD_ROOT}/plugins/tool/orch-sequential/plugin.sh"
    if [[ "$backend" == "sequential" && -f "$sequential_sh" ]]; then
        # shellcheck disable=SC1090
        source "$sequential_sh"
        _ZBUILD_ORCH_BACKEND_LOADED=1
        return 0
    fi

    # No plugin found for requested backend — fall back to sequential (built-in)
    if [[ -f "$sequential_sh" ]]; then
        warn "orch_load_backend: backend '${backend}' not found; falling back to sequential" || true
        # shellcheck disable=SC1090
        source "$sequential_sh"
        _ZBUILD_ORCH_BACKEND_LOADED=1
        return 0
    fi

    # Nothing found at all — warn and return 1
    warn "orch_load_backend: backend '${backend}' not found (no plugin for role orchestrator-backend with alias ${backend})" || true
    return 1
}

# ─── _orch_load_backend (internal) ───────────────────────────────────────────
# Called at end of file to auto-load the configured backend.
# Skips auto-loading if a backend has already provided the contract functions
# (i.e., when a plugin sources the backend before sourcing this contract file).
_orch_load_backend() {
    # If a real backend was already sourced (sentinel set to 1), skip auto-load
    # to avoid overwriting the pre-loaded backend's implementations.
    # Note: the stubs above do NOT set this sentinel, so checking declare -F
    # would always return true (stubs are defined).  We use the sentinel instead.
    [[ "${_ZBUILD_ORCH_BACKEND_LOADED:-0}" -eq 1 ]] && return 0

    local backend

    # Get configured backend, falling back to "sequential" if config unavailable
    if declare -F zbuild_config_get_backend >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "orchestrator" 2>/dev/null)" || backend="sequential"
    else
        backend="${ZBUILD_ORCHESTRATOR_BACKEND:-sequential}"
    fi

    # Attempt to load the configured backend; if it fails, that is OK —
    # the stubs remain and callers will get informative errors.
    orch_load_backend "$backend" 2>/dev/null || true
}

# Auto-load at source time — skipped if _ZBUILD_ORCH_BACKEND_LOADED is already 1
_orch_load_backend
