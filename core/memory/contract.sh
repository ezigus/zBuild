#!/usr/bin/env bash
# core/memory/contract.sh — Memory backend contract layer (issue #215, ADR-011, ADR-014)
# Sourced library: no set -euo pipefail.
# Guard: safe even when caller has set -u.
# Init timing: eager auto-load at source time (ADR-014), matching cache + orch.

[[ -n "${_ZBUILD_MEMORY_CONTRACT_LOADED:-}" ]] && return 0
_ZBUILD_MEMORY_CONTRACT_LOADED=1

# ─── Module vars ──────────────────────────────────────────────────────────────
_ZBUILD_MEMORY_BACKEND=""
_ZBUILD_MEMORY_PLUGIN_DIR=""
_ZBUILD_MEMORY_INITIALIZED=0

# ─── _memory_contract_dir — locate this file's directory ─────────────────────
_MEMORY_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="${_ZBUILD_ROOT:-$(cd "$_MEMORY_CONTRACT_DIR/../.." && pwd)}"

# ─── memory_has_capability <cap> ─────────────────────────────────────────────
# exit 0 if backend declares capability; exit 1 if not or if memory_capabilities
# is not defined.
memory_has_capability() {
    local cap="$1"
    if ! declare -F "memory_capabilities" >/dev/null 2>&1; then
        return 1
    fi
    local caps
    caps="$(memory_capabilities 2>/dev/null)" || return 1
    if printf '%s' "$caps" | grep -qF "\"${cap}\"" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ─── _memory_load_backend ────────────────────────────────────────────────────
# Internal: called at file-end for eager auto-load (ADR-014).
# Non-fatal on failure: warns + leaves stubs in place so callers can detect
# the uninitialized state via declare -F checks.
_memory_load_backend() {
    [[ "${_ZBUILD_MEMORY_INITIALIZED:-0}" -eq 1 ]] && return 0

    local backend=""
    if [[ -n "${ZBUILD_MEMORY_BACKEND:-}" ]]; then
        backend="${ZBUILD_MEMORY_BACKEND}"
    elif declare -F "zbuild_config_get_backend" >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "memory" 2>/dev/null || true)"
    fi
    [[ -z "$backend" ]] && backend="sqlite"

    _ZBUILD_MEMORY_BACKEND="$backend"

    local plugin_dir="" plugin_sh=""

    if [[ "$backend" == "sqlite" ]]; then
        plugin_sh="$_ZBUILD_ROOT/plugins/tool/memory-sqlite/plugin.sh"
        plugin_dir="$_ZBUILD_ROOT/plugins/tool/memory-sqlite"
    else
        if declare -F "find_plugin_for_role" >/dev/null 2>&1; then
            local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
            plugin_dir="$(find_plugin_for_role "memory-backend" "$backend" "$plugins_root" 2>/dev/null || true)"
        fi

        if [[ -z "$plugin_dir" ]]; then
            if [[ "${ZBUILD_MEMORY_FALLBACK:-}" == "true" ]]; then
                if declare -F "eb_emit_event" >/dev/null 2>&1; then
                    eb_emit_event "backend.degraded" \
                        "role=memory-backend" "requested=$backend" "fallback=sqlite" 2>/dev/null || true
                fi
                warn "[memory] backend '$backend' not found; falling back to sqlite" >&2 || true
                plugin_sh="$_ZBUILD_ROOT/plugins/tool/memory-sqlite/plugin.sh"
                plugin_dir="$_ZBUILD_ROOT/plugins/tool/memory-sqlite"
                _ZBUILD_MEMORY_BACKEND="sqlite"
            else
                warn "[memory] backend '$backend' not found and ZBUILD_MEMORY_FALLBACK not set" >&2 || true
                return 0
            fi
        else
            plugin_sh="$plugin_dir/plugin.sh"
        fi
    fi

    _ZBUILD_MEMORY_PLUGIN_DIR="$plugin_dir"

    if [[ ! -f "$plugin_sh" ]]; then
        warn "[memory] plugin.sh not found: $plugin_sh" >&2 || true
        return 0
    fi

    # shellcheck disable=SC1090
    source "$plugin_sh"

    if declare -F "memory_backend_init" >/dev/null 2>&1; then
        memory_backend_init || {
            warn "[memory] memory_backend_init failed" >&2 || true
            return 0
        }
    fi

    local required_fns=(memory_put memory_get memory_search memory_list_namespaces memory_namespace_exists memory_namespace_clear)
    local missing_count=0
    for fn in "${required_fns[@]}"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            warn "[memory] backend '$_ZBUILD_MEMORY_BACKEND' missing required function: $fn" >&2 || true
            missing_count=$((missing_count + 1))
        fi
    done
    if [[ "$missing_count" -gt 0 ]]; then
        warn "[memory] $missing_count required function(s) missing from '$_ZBUILD_MEMORY_BACKEND'" >&2 || true
        return 0
    fi

    _ZBUILD_MEMORY_INITIALIZED=1

    if declare -F "eb_emit_event" >/dev/null 2>&1; then
        eb_emit_event "memory.backend.init" \
            "backend=$_ZBUILD_MEMORY_BACKEND" \
            "plugin_dir=$_ZBUILD_MEMORY_PLUGIN_DIR" 2>/dev/null || true
    fi
}

# ─── memory_init ─────────────────────────────────────────────────────────────
# Public idempotent wrapper — kept for callers that call it explicitly
# (e.g., runner.sh:20). After ADR-014, the actual init happens at file-end
# via _memory_load_backend, so this is usually a no-op.
memory_init() {
    _memory_load_backend
}

# ─── Eager auto-load (ADR-014) ───────────────────────────────────────────────
_memory_load_backend
