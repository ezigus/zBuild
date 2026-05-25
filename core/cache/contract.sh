#!/usr/bin/env bash
# core/cache/contract.sh — Cache backend contract layer (ADR-011)
# Sourced library: no set -euo pipefail. Sourced by bootstrap.sh and teardown.sh.

[[ -n "${_ZBUILD_CACHE_CONTRACT_LOADED:-}" ]] && return 0
_ZBUILD_CACHE_CONTRACT_LOADED=1

_ZBUILD_CACHE_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "${_ZBUILD_CACHE_CONTRACT_DIR}/../.." && pwd)"

# ─── ZBUILD_CACHE_DIR — test isolation hook ──────────────────────────────────
export ZBUILD_CACHE_DIR="${ZBUILD_CACHE_DIR:-${HOME}/.zbuild/cache}"

# ─── cache_derive_key <repo> <branch> <slot> ────────────────────────────────
# Prints a deterministic, filesystem-safe cache key.
# Format: zbuild-<7hexchars>-<sanitized-branch>-<sanitized-slot>
# Total key max 64 chars. Matches ^[A-Za-z0-9_.-]+$.
cache_derive_key() {
    local repo="$1"
    local branch="$2"
    local slot="$3"

    # Compute 7-char SHA-256 prefix of "repo/branch"
    local hash_input="${repo}/${branch}"
    local hash7
    if command -v sha256sum >/dev/null 2>&1; then
        hash7="$(printf '%s' "$hash_input" | sha256sum | cut -c1-7)"
    else
        hash7="$(printf '%s' "$hash_input" | shasum -a 256 | cut -c1-7)"
    fi

    # Sanitize branch: replace non-alphanumeric (except _ . -) with -, max 40 chars
    local safe_branch
    safe_branch="${branch//[^a-zA-Z0-9_.-]/-}"
    safe_branch="${safe_branch:0:40}"

    # Sanitize slot: replace non-alphanumeric (except _ . -) with -, max 40 chars
    local safe_slot
    safe_slot="${slot//[^a-zA-Z0-9_.-]/-}"
    safe_slot="${safe_slot:0:40}"

    # Assemble key
    local key="zbuild-${hash7}-${safe_branch}-${safe_slot}"

    # Truncate to 64 chars total
    key="${key:0:64}"

    printf '%s' "$key"
}

# ─── cache_has_capability <cap_name> ────────────────────────────────────────
# Exit 0 if cache_capabilities output contains the capability, exit 1 otherwise.
cache_has_capability() {
    local cap_name="$1"
    local caps
    caps="$(cache_capabilities 2>/dev/null)" || return 1
    if printf '%s' "$caps" | grep -qF "\"${cap_name}\""; then
        return 0
    fi
    return 1
}

# ─── Backend loading ─────────────────────────────────────────────────────────
# Executed at sourcing time. Determines backend, sources plugin, verifies API.

_zbuild_cache_load_backend() {
    local backend

    # 1. Env override
    if [[ -n "${ZBUILD_CACHE_BACKEND:-}" ]]; then
        backend="$ZBUILD_CACHE_BACKEND"
    # 2. Config function (if available)
    elif declare -F zbuild_config_get_backend >/dev/null 2>&1; then
        backend="$(zbuild_config_get_backend "cache" 2>/dev/null)" || true
        backend="${backend:-local}"
    else
        backend="local"
    fi

    # 3. Source the backend plugin
    if [[ "$backend" == "local" ]]; then
        # Built-in local backend — source directly
        local local_plugin="${_ZBUILD_ROOT}/plugins/tool/cache-local/plugin.sh"
        if [[ -f "$local_plugin" ]]; then
            # shellcheck source=../../plugins/tool/cache-local/plugin.sh
            source "$local_plugin"
        else
            echo "[cache] WARN: local backend plugin not found: $local_plugin" >&2
        fi
    else
        # Non-local: use find_plugin_for_role
        local plugin_dir=""
        if declare -F find_plugin_for_role >/dev/null 2>&1; then
            plugin_dir="$(find_plugin_for_role "cache-backend" "$backend" 2>/dev/null)" || true
        fi

        if [[ -n "$plugin_dir" && -f "${plugin_dir}/plugin.sh" ]]; then
            # shellcheck disable=SC1090
            source "${plugin_dir}/plugin.sh"
        else
            echo "[cache] WARN: backend '${backend}' not found; falling back to local" >&2
            local local_plugin="${_ZBUILD_ROOT}/plugins/tool/cache-local/plugin.sh"
            if [[ -f "$local_plugin" ]]; then
                # shellcheck source=../../plugins/tool/cache-local/plugin.sh
                source "$local_plugin"
            fi
        fi
    fi

    # 4. Verify required API functions are defined
    local missing=0
    for fn in cache_pull cache_push cache_capabilities; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            echo "[cache] WARN: backend '${backend}' did not define ${fn}" >&2
            missing=$((missing + 1))
        fi
    done

    return 0
}

_zbuild_cache_load_backend
