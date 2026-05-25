#!/usr/bin/env bash
# plugins/tool/cache-gh-actions/plugin.sh — GitHub Actions cache backend (ADR-011)
# Sourced library: no set -euo pipefail.
#
# Uses $RUNNER_TEMP/zbuild-cache/<key>/ as the within-run store.
# Cross-run persistence is handled by the surrounding workflow's actions/cache step.
#
# When RUNNER_TEMP is not set or invalid, cache_pull gracefully returns CACHE_MISS
# and cache_push is a no-op (rc=0). This allows local dev pipelines to work without
# modification. Hard infrastructure errors (copy failure, unwritable dirs) still
# return non-zero.

[[ -n "${_ZBUILD_CACHE_GHA_LOADED:-}" ]] && return 0
_ZBUILD_CACHE_GHA_LOADED=1

# ─── _cache_gha_validate_runner_temp ────────────────────────────────────────
# Returns 0 if RUNNER_TEMP is a safe absolute directory; 1 otherwise.
_cache_gha_validate_runner_temp() {
    local rt="${RUNNER_TEMP:-}"
    [[ -z "$rt" ]] && return 1
    [[ "$rt" != /* ]] && return 1
    [[ "$rt" == "/" ]] && return 1
    [[ ! -d "$rt" ]] && return 1
    return 0
}

# ─── cache_pull <key> <dest_dir> ────────────────────────────────────────────
# Copies cached content from RUNNER_TEMP/zbuild-cache/<key>/ into dest_dir.
# Prints CACHE_HIT or CACHE_MISS to stdout.  Never exits non-zero on a miss.
# Gracefully returns CACHE_MISS (rc=0) when RUNNER_TEMP is unset/invalid.
cache_pull() {
    local key="$1"
    local dest_dir="$2"

    # Validate key — must only contain [a-zA-Z0-9_.-] and no path separators
    if [[ -z "$key" || "$key" =~ [^a-zA-Z0-9_.\-] || "$key" == *".."* ]]; then
        echo "cache: invalid key: $key" >&2
        return 2
    fi

    # Graceful degradation: if RUNNER_TEMP is unset/invalid, return CACHE_MISS
    if ! _cache_gha_validate_runner_temp; then
        echo "CACHE_MISS"
        return 0
    fi

    # dest_dir must not already exist as a regular file
    if [[ -e "$dest_dir" && ! -d "$dest_dir" ]]; then
        echo "cache_pull: dest_dir exists but is not a directory: $dest_dir" >&2
        return 1
    fi

    local src="${RUNNER_TEMP}/zbuild-cache/${key}"

    mkdir -p "$dest_dir" || {
        echo "cache_pull: failed to create dest_dir: $dest_dir" >&2
        return 1
    }

    if [[ ! -d "$src" ]]; then
        echo "CACHE_MISS"
        return 0
    fi

    if cp -r "${src}/." "${dest_dir}/" 2>/dev/null; then
        echo "CACHE_HIT"
        return 0
    else
        echo "cache_pull: copy failed from ${src} to ${dest_dir}" >&2
        return 1
    fi
}

# ─── cache_push <key> <src_dir> ─────────────────────────────────────────────
# Stores content of src_dir under the given key in RUNNER_TEMP/zbuild-cache/.
# Uses atomic pattern: copy to .tmp.<pid>, then lock-protected mv.
# Gracefully no-ops (rc=0) when RUNNER_TEMP is unset/invalid.
cache_push() {
    local key="$1"
    local src_dir="$2"

    # Validate key — must only contain [a-zA-Z0-9_.-] and no path separators
    if [[ -z "$key" || "$key" =~ [^a-zA-Z0-9_.\-] || "$key" == *".."* ]]; then
        echo "cache: invalid key: $key" >&2
        return 2
    fi

    # Graceful degradation: if RUNNER_TEMP is unset/invalid, silently skip
    if ! _cache_gha_validate_runner_temp; then
        return 0
    fi

    if [[ ! -d "$src_dir" ]]; then
        echo "cache_push: source directory not found: $src_dir" >&2
        return 1
    fi

    local cache_root="${RUNNER_TEMP}/zbuild-cache"
    local dest="${cache_root}/${key}"

    # Size guard: warn and invalidate stale entry when over limit.
    # Removing the existing key prevents a misleading CACHE_HIT on stale data.
    local max_kb=$(( ${ZBUILD_CACHE_MAX_MB:-2048} * 1024 ))
    local size_kb
    size_kb="$(du -sk "$src_dir" 2>/dev/null | cut -f1)" || size_kb=0
    if [[ "$size_kb" -gt "$max_kb" ]]; then
        echo "cache_push: WARNING: src_dir size ${size_kb}k exceeds limit ${max_kb}k; removing stale entry and skipping push" >&2
        rm -rf "$dest" 2>/dev/null || true
        return 0
    fi

    # Use a PID-unique tmp path so concurrent pushes don't collide on the tmp name.
    local _push_pid="${BASHPID:-$$}"
    local dest_tmp="${cache_root}/${key}.tmp.${_push_pid}"
    local lock_file="${cache_root}/.lock.${key}"

    rm -rf "$dest_tmp" 2>/dev/null || true
    mkdir -p "$dest_tmp" || {
        echo "cache_push: failed to create tmp dir: $dest_tmp" >&2
        return 1
    }

    if ! cp -r "${src_dir}/." "${dest_tmp}/" 2>/dev/null; then
        echo "cache_push: copy failed from ${src_dir} to ${dest_tmp}" >&2
        rm -rf "$dest_tmp" 2>/dev/null || true
        return 1
    fi

    # Lock-protected atomic swap: prevents concurrent push race where mv moves
    # dest_tmp INTO an existing dest directory instead of replacing it.
    local swap_rc=0
    (
        flock 9
        rm -rf "$dest" 2>/dev/null || true
        mv "$dest_tmp" "$dest" || { rm -rf "$dest_tmp" 2>/dev/null || true; exit 1; }
    ) 9>"$lock_file"
    swap_rc=$?
    rm -f "$lock_file" 2>/dev/null || true

    if [[ $swap_rc -ne 0 ]]; then
        echo "cache_push: atomic move failed: ${dest_tmp} -> ${dest}" >&2
        rm -rf "$dest_tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# ─── cache_capabilities ─────────────────────────────────────────────────────
# Prints backend capabilities as JSON to stdout.
cache_capabilities() {
    echo '{"backend":"gh-actions-cache","capabilities":["github_actions","runner_temp","cross_job"]}'
}
