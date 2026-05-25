#!/usr/bin/env bash
# plugins/tool/cache-local/plugin.sh — Local filesystem cache backend (ADR-011)
# Sourced library: no set -euo pipefail.

# ─── cache_pull <key> <dest_dir> ────────────────────────────────────────────
# Copies cached content into dest_dir.
# Prints CACHE_HIT or CACHE_MISS to stdout.
# Never exits non-zero on a miss (miss is normal).
cache_pull() {
    local key="$1"
    local dest_dir="$2"
    local cache_dir="${ZBUILD_CACHE_DIR:-${HOME}/.zbuild/cache}"
    local src="${cache_dir}/${key}"

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
# Stores content of src_dir under the given key.
# Uses atomic pattern: copy to .tmp, then mv.
cache_push() {
    local key="$1"
    local src_dir="$2"
    local cache_dir="${ZBUILD_CACHE_DIR:-${HOME}/.zbuild/cache}"
    local dest="${cache_dir}/${key}"
    local dest_tmp="${cache_dir}/${key}.tmp"

    if [[ ! -d "$src_dir" ]]; then
        echo "cache_push: source directory not found: $src_dir" >&2
        return 1
    fi

    # Remove stale tmp if present
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
        echo "cache_push: atomic move failed: ${dest_tmp} → ${dest}" >&2
        rm -rf "$dest_tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# ─── cache_capabilities ─────────────────────────────────────────────────────
# Prints backend capabilities as JSON to stdout.
cache_capabilities() {
    echo '{"backend":"local","capabilities":["local_filesystem","persistent"]}'
}
