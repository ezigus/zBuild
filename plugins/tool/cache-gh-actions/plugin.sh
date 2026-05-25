#!/usr/bin/env bash
# plugins/tool/cache-gh-actions/plugin.sh — GitHub Actions cache backend (ADR-011)
# Sourced library: no set -euo pipefail.
#
# Uses $RUNNER_TEMP/zbuild-cache/<key>/ as the within-run store.
# Cross-run persistence is handled by the surrounding workflow's actions/cache step.
# Requires RUNNER_TEMP to be a valid, non-root absolute directory path.

[[ -n "${_ZBUILD_CACHE_GHA_LOADED:-}" ]] && return 0
_ZBUILD_CACHE_GHA_LOADED=1

# ─── _cache_gha_validate_runner_temp ────────────────────────────────────────
# Returns 0 if RUNNER_TEMP is a safe, non-root absolute directory.
# Returns 1 otherwise.  Caller must also check that the variable is set.
_cache_gha_validate_runner_temp() {
    local rt="${RUNNER_TEMP:-}"
    [[ -z "$rt" ]] && return 1
    [[ "$rt" != /* ]] && return 1
    [[ "$rt" == "/" || "$rt" == "/tmp" || "$rt" == "/var" || "$rt" == "$HOME" ]] && return 1
    [[ ! -d "$rt" ]] && return 1
    return 0
}

# ─── _cache_gha_check_env ───────────────────────────────────────────────────
# Validates that RUNNER_TEMP is set and safe.
# Prints a diagnostic to stderr and returns 1 on failure.
_cache_gha_check_env() {
    local rt="${RUNNER_TEMP:-}"
    if [[ -z "$rt" ]]; then
        echo "cache-gh-actions: RUNNER_TEMP is not set; cannot use GH Actions cache backend" >&2
        return 1
    fi
    if ! _cache_gha_validate_runner_temp; then
        echo "cache-gh-actions: RUNNER_TEMP='${rt}' is not a safe absolute directory path" >&2
        return 1
    fi
    return 0
}

# ─── cache_pull <key> <dest_dir> ────────────────────────────────────────────
# Copies cached content from RUNNER_TEMP/zbuild-cache/<key>/ into dest_dir.
# Prints CACHE_HIT or CACHE_MISS to stdout.
# Never exits non-zero on a cache miss (miss is normal).
# Exits non-zero if RUNNER_TEMP is unset/invalid or on infrastructure error.
cache_pull() {
    local key="$1"
    local dest_dir="$2"

    # Validate key — must only contain [a-zA-Z0-9_.-] and no path separators
    if [[ -z "$key" || "$key" =~ [^a-zA-Z0-9_.\-] || "$key" == *".."* ]]; then
        echo "cache: invalid key: $key" >&2
        return 2
    fi

    # Validate RUNNER_TEMP
    _cache_gha_check_env || return 1

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
# Uses atomic pattern: copy to .tmp, then mv.
# Exits non-zero if RUNNER_TEMP is unset/invalid or src_dir is missing/unreadable.
cache_push() {
    local key="$1"
    local src_dir="$2"

    # Validate key — must only contain [a-zA-Z0-9_.-] and no path separators
    if [[ -z "$key" || "$key" =~ [^a-zA-Z0-9_.\-] || "$key" == *".."* ]]; then
        echo "cache: invalid key: $key" >&2
        return 2
    fi

    # Validate RUNNER_TEMP
    _cache_gha_check_env || return 1

    if [[ ! -d "$src_dir" ]]; then
        echo "cache_push: source directory not found: $src_dir" >&2
        return 1
    fi

    # Size guard: warn but do not fail if over limit
    local max_kb=$(( ${ZBUILD_CACHE_MAX_MB:-2048} * 1024 ))
    local size_kb
    size_kb="$(du -sk "$src_dir" 2>/dev/null | cut -f1)" || size_kb=0
    if [[ "$size_kb" -gt "$max_kb" ]]; then
        echo "cache_push: WARNING: src_dir size ${size_kb}k exceeds limit ${max_kb}k; skipping push" >&2
        return 0
    fi

    local cache_root="${RUNNER_TEMP}/zbuild-cache"
    local dest="${cache_root}/${key}"
    # Use a PID-unique tmp path so concurrent pushes don't collide.
    # $BASHPID (not $$) gives the actual subshell PID; $$ returns the parent.
    local _push_pid="${BASHPID:-$$}"
    local dest_tmp="${cache_root}/${key}.tmp.${_push_pid}"

    # Clean up our own stale tmp if present (from a previous crashed run)
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

    # Atomic swap: remove old dest, move tmp into place
    rm -rf "$dest" 2>/dev/null || true
    if ! mv "$dest_tmp" "$dest" 2>/dev/null; then
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
