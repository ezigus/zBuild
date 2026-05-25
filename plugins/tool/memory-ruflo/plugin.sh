#!/usr/bin/env bash
# plugins/tool/memory-ruflo/plugin.sh — ruflo HNSW vector memory backend (issue #217)
# ADR-011: pluggable memory backend. Optional; requires ruflo + jq on PATH.
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MEMORY_RUFLO_LOADED:-}" ]] && return 0
_ZBUILD_MEMORY_RUFLO_LOADED=1

_ZBUILD_ROOT="${_ZBUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
_MEMORY_RUFLO_AVAILABLE=0
_MEMORY_RUFLO_REPO_HASH=""

# ─── _memory_ruflo_ns — scope a user namespace under a repo-specific prefix ────
_memory_ruflo_ns() {
    printf 'zbuild-repo-%s-%s' "$_MEMORY_RUFLO_REPO_HASH" "$1"
}

# ─── _memory_ruflo_repo_hash — cross-platform sha256 of repo root ────────────
_memory_ruflo_repo_hash() {
    local root="${ZBUILD_ROOT:-$(pwd)}"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$root" | sha256sum | cut -c1-12
    else
        printf '%s' "$root" | shasum -a 256 | cut -c1-12
    fi
}

# ─── memory_capabilities ─────────────────────────────────────────────────────
memory_capabilities() {
    printf '["vector_search","hnsw","namespacing","persistence"]\n'
}

# ─── memory_backend_init ─────────────────────────────────────────────────────
# exit 0: ruflo + jq available; exit 1: missing dependency
memory_backend_init() {
    local _ruflo_bin
    _ruflo_bin="$(command -v ruflo 2>/dev/null)" || true
    if [[ -z "$_ruflo_bin" || ! -x "$_ruflo_bin" ]]; then
        warn "memory-ruflo: ruflo binary not found in PATH" >&2 || true
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        warn "memory-ruflo: jq not found; required for JSON output parsing" >&2 || true
        return 1
    fi
    _MEMORY_RUFLO_REPO_HASH="$(_memory_ruflo_repo_hash)"
    _MEMORY_RUFLO_AVAILABLE=1
    return 0
}

# ─── memory_put <ns> <key> <value> ───────────────────────────────────────────
# exit 0: success; exit 1: backend error; exit 2: invalid args (empty key/ns)
memory_put() {
    local ns="$1" key="$2" value="${3:-}"
    [[ -z "$ns" || -z "$key" ]] && return 2

    local scoped_ns
    scoped_ns="$(_memory_ruflo_ns "$ns")"

    ruflo memory store -k "$key" --value "$value" -n "$scoped_ns" --upsert --quiet >/dev/null 2>/dev/null || {
        warn "memory-ruflo: memory_put failed for key='$key' ns='$ns'" >&2 || true
        return 1
    }
    return 0
}

# ─── memory_get <ns> <key> ───────────────────────────────────────────────────
# exit 0 always (empty stdout = miss); exit 1 on unrecoverable backend error
# ruflo rc=1 is treated as a miss (ruflo uses rc=1 for both miss and error)
memory_get() {
    local ns="$1" key="$2"
    [[ -z "$ns" || -z "$key" ]] && return 0

    local scoped_ns
    scoped_ns="$(_memory_ruflo_ns "$ns")"

    local raw
    raw="$(ruflo memory retrieve -k "$key" -n "$scoped_ns" --format json --quiet 2>/dev/null)" || return 0
    printf '%s' "$raw" | jq -r '.content // empty' 2>/dev/null
    return 0
}

# ─── memory_search <ns> <query> [--limit N] ──────────────────────────────────
# exit 0 always (no output = no matches); exit 1 on error; exit 2 on bad args
# Output: one <key>\t<value> per line; embedded newlines in value escaped as \n
memory_search() {
    local ns="$1" query="$2"
    local limit=10

    if [[ "${3:-}" == "--limit" && -n "${4:-}" ]]; then
        if [[ ! "${4}" =~ ^[0-9]+$ ]]; then
            printf 'memory_search: --limit value must be a non-negative integer\n' >&2
            return 2
        fi
        limit="$4"
    fi

    local scoped_ns
    scoped_ns="$(_memory_ruflo_ns "$ns")"

    local raw rc
    raw="$(ruflo memory search -q "$query" -n "$scoped_ns" -t semantic -l "$limit" --format json --quiet 2>/dev/null)"
    rc=$?

    if [[ $rc -ne 0 && $rc -gt 1 ]]; then
        warn "memory-ruflo: memory_search failed (rc=$rc) for query='$query' ns='$ns'" >&2 || true
        return 1
    fi
    # rc=1 means no matches (ruflo convention) — return 0 with empty output
    [[ $rc -eq 1 ]] && return 0
    [[ -z "$raw" ]] && return 0

    # Parse keys from results, then retrieve full value for each
    local keys
    keys="$(printf '%s' "$raw" | jq -r '.results[]?.key // empty' 2>/dev/null)" || return 0
    [[ -z "$keys" ]] && return 0

    while IFS= read -r result_key; do
        [[ -z "$result_key" ]] && continue
        local val
        val="$(memory_get "$ns" "$result_key")"
        # Escape embedded newlines
        val="${val//$'\n'/\\n}"
        printf '%s\t%s\n' "$result_key" "$val"
    done <<< "$keys"

    return 0
}

# ─── memory_list_namespaces ───────────────────────────────────────────────────
# exit 0 always (graceful degradation on error — empty output means no namespaces)
# Output: one namespace name per line (prefix stripped)
memory_list_namespaces() {
    local raw rc
    raw="$(ruflo memory list --format json --quiet -l 10000 2>/dev/null)"
    rc=$?
    [[ $rc -ne 0 ]] && return 0

    printf '%s' "$raw" | jq -r --arg prefix "zbuild-repo-${_MEMORY_RUFLO_REPO_HASH}-" \
        '.[].namespace | select(startswith($prefix)) | ltrimstr($prefix)' 2>/dev/null \
        | sort -u
    return 0
}

# ─── memory_namespace_exists <ns> ────────────────────────────────────────────
# exit 0 if exists; exit 1 if absent or error (UNSAFE under set -e — use || true)
memory_namespace_exists() {
    local ns="$1"
    [[ -z "$ns" ]] && return 1

    local scoped_ns
    scoped_ns="$(_memory_ruflo_ns "$ns")"

    local raw rc
    raw="$(ruflo memory list -n "$scoped_ns" --format json --quiet -l 1 2>/dev/null)"
    rc=$?
    [[ $rc -ne 0 ]] && return 1

    local length
    length="$(printf '%s' "$raw" | jq 'length' 2>/dev/null)"
    [[ "${length:-0}" -gt 0 ]] && return 0
    return 1
}

# ─── memory_namespace_clear <ns> ─────────────────────────────────────────────
# exit 0 success/idempotent; exit 1 on error
memory_namespace_clear() {
    local ns="$1"
    [[ -z "$ns" ]] && return 0

    local scoped_ns
    scoped_ns="$(_memory_ruflo_ns "$ns")"

    local raw rc
    raw="$(ruflo memory list -n "$scoped_ns" --format json --quiet -l 10000 2>/dev/null)"
    rc=$?
    [[ $rc -ne 0 ]] && return 1

    local length
    length="$(printf '%s' "$raw" | jq 'length' 2>/dev/null)"
    [[ "${length:-0}" -eq 0 ]] && return 0

    local errors=0
    local keys
    keys="$(printf '%s' "$raw" | jq -r '.[].key // empty' 2>/dev/null)" || return 1

    while IFS= read -r del_key; do
        [[ -z "$del_key" ]] && continue
        ruflo memory delete -k "$del_key" -n "$scoped_ns" -f --quiet >/dev/null 2>/dev/null || {
            errors=$((errors + 1))
        }
    done <<< "$keys"

    if [[ $errors -gt 0 ]]; then
        warn "memory-ruflo: memory_namespace_clear: $errors key(s) failed to delete in ns='$ns'" >&2 || true
        return 1
    fi
    return 0
}
