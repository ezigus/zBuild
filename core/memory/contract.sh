#!/usr/bin/env bash
# core/memory/contract.sh — Memory backend contract layer (issue #215, ADR-011)
# Sourced library: no set -euo pipefail.
# Guard: safe even when caller has set -u.

[[ -n "${_ZBUILD_MEMORY_CONTRACT_LOADED:-}" ]] && return 0
_ZBUILD_MEMORY_CONTRACT_LOADED=1

# ─── Module vars ──────────────────────────────────────────────────────────────
_ZBUILD_MEMORY_BACKEND=""
_ZBUILD_MEMORY_PLUGIN_DIR=""
_ZBUILD_MEMORY_INITIALIZED=0

# ─── _memory_contract_dir — locate this file's directory ─────────────────────
_MEMORY_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="${_ZBUILD_ROOT:-$(cd "$_MEMORY_CONTRACT_DIR/../.." && pwd)}"

# ─── _memory_not_initialized — emitted by stubs when no backend is loaded ────
_memory_not_initialized() {
    local fn="${1:-memory}"
    printf '%s: memory backend not initialized; call memory_init first\n' "$fn" >&2
    return 1
}

# NOTE: No stub implementations of the 6 required functions are defined here.
# The backend's plugin.sh is the sole provider of those implementations.
# This ensures that declare -F checks in memory_init accurately reflect
# whether a backend was successfully sourced.

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

# ─── memory_init ─────────────────────────────────────────────────────────────
# Called once by runner.sh after zbuild_config_init. Idempotent.
memory_init() {
    # Idempotency guard
    [[ "${_ZBUILD_MEMORY_INITIALIZED:-0}" -eq 1 ]] && return 0

    # ── Determine backend name ────────────────────────────────────────────────
    local backend=""
    # 1. Env override (ZBUILD_MEMORY_BACKEND)
    if [[ -n "${ZBUILD_MEMORY_BACKEND:-}" ]]; then
        backend="${ZBUILD_MEMORY_BACKEND}"
    # 2. Config layer
    elif declare -F "zbuild_config_get_backend" >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "memory" 2>/dev/null || true)"
    fi
    # 3. Default
    [[ -z "$backend" ]] && backend="sqlite"

    _ZBUILD_MEMORY_BACKEND="$backend"

    # ── Source the backend plugin.sh ──────────────────────────────────────────
    local plugin_dir=""
    local plugin_sh=""

    if [[ "$backend" == "sqlite" ]]; then
        # SQLite is the built-in default — source directly
        plugin_sh="$_ZBUILD_ROOT/plugins/tool/memory-sqlite/plugin.sh"
        plugin_dir="$_ZBUILD_ROOT/plugins/tool/memory-sqlite"
    else
        # Non-default: locate via registry
        if declare -F "find_plugin_for_role" >/dev/null 2>&1; then
            local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}"
            plugin_dir="$(find_plugin_for_role "memory-backend" "$backend" "$plugins_root" 2>/dev/null || true)"
        fi

        if [[ -z "$plugin_dir" ]]; then
            # Plugin not found
            if [[ "${ZBUILD_MEMORY_FALLBACK:-}" == "true" ]]; then
                # Emit degraded event and fall back to sqlite
                if declare -F "eb_emit_event" >/dev/null 2>&1; then
                    eb_emit_event "backend.degraded" \
                        "role=memory-backend" \
                        "requested=$backend" \
                        "fallback=sqlite" 2>/dev/null || true
                fi
                warn "memory_init: backend '$backend' not found; falling back to sqlite" >&2 || true
                plugin_sh="$_ZBUILD_ROOT/plugins/tool/memory-sqlite/plugin.sh"
                plugin_dir="$_ZBUILD_ROOT/plugins/tool/memory-sqlite"
                _ZBUILD_MEMORY_BACKEND="sqlite"
            else
                warn "memory_init: backend '$backend' not found and ZBUILD_MEMORY_FALLBACK not set" >&2 || true
                return 1
            fi
        else
            plugin_sh="$plugin_dir/plugin.sh"
        fi
    fi

    _ZBUILD_MEMORY_PLUGIN_DIR="$plugin_dir"

    if [[ ! -f "$plugin_sh" ]]; then
        warn "memory_init: plugin.sh not found: $plugin_sh" >&2 || true
        return 1
    fi

    # Source backend into current process (NOT via plugin_hook_call subshell)
    # shellcheck disable=SC1090
    source "$plugin_sh"

    # ── Call memory_backend_init if defined ───────────────────────────────────
    if declare -F "memory_backend_init" >/dev/null 2>&1; then
        memory_backend_init || {
            warn "memory_init: memory_backend_init failed" >&2 || true
            return 1
        }
    fi

    # ── Verify all 6 required functions are defined ───────────────────────────
    local required_fns=(memory_put memory_get memory_search memory_list_namespaces memory_namespace_exists memory_namespace_clear)
    local missing_count=0
    for fn in "${required_fns[@]}"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            warn "memory_init: backend '$_ZBUILD_MEMORY_BACKEND' did not define required function: $fn" >&2 || true
            missing_count=$((missing_count + 1))
        fi
    done
    if [[ "$missing_count" -gt 0 ]]; then
        warn "memory_init: $missing_count required function(s) missing from backend '$_ZBUILD_MEMORY_BACKEND'" >&2 || true
        return 1
    fi

    # ── Mark initialized ──────────────────────────────────────────────────────
    _ZBUILD_MEMORY_INITIALIZED=1

    # ── Emit init event ───────────────────────────────────────────────────────
    if declare -F "eb_emit_event" >/dev/null 2>&1; then
        eb_emit_event "memory.backend.init" \
            "backend=$_ZBUILD_MEMORY_BACKEND" \
            "plugin_dir=$_ZBUILD_MEMORY_PLUGIN_DIR" 2>/dev/null || true
    fi

    return 0
}
