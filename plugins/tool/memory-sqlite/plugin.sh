#!/usr/bin/env bash
# plugins/tool/memory-sqlite/plugin.sh — SQLite memory backend (issue #215)
# ADR-011: pluggable memory backend. Default backend for zbuild.
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MEMORY_SQLITE_LOADED:-}" ]] && return 0
_ZBUILD_MEMORY_SQLITE_LOADED=1

# ─── DB path resolution ──────────────────────────────────────────────────────
# Priority: ZBUILD_MEMORY_DB → ${ZBUILD_STATE_DIR}/memory.db → ~/.zbuild/state/memory.db
_memory_sqlite_db_path() {
    if [[ -n "${ZBUILD_MEMORY_DB:-}" ]]; then
        echo "$ZBUILD_MEMORY_DB"
    elif [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
        echo "${ZBUILD_STATE_DIR}/memory.db"
    else
        echo "${HOME}/.zbuild/state/memory.db"
    fi
}

# ─── memory_capabilities ─────────────────────────────────────────────────────
memory_capabilities() {
    printf '["text_search","namespacing","persistence"]\n'
}

# ─── memory_backend_init ─────────────────────────────────────────────────────
# Called by memory_init after sourcing this file. Creates schema.
memory_backend_init() {
    local db
    db="$(_memory_sqlite_db_path)"
    mkdir -p "$(dirname "$db")"

    if ! command -v sqlite3 >/dev/null 2>&1; then
        warn "memory-sqlite: sqlite3 not found; memory operations will fail" >&2 || true
        return 1
    fi

    local err
    err="$(sqlite3 "$db" <<'SQL' 2>&1
CREATE TABLE IF NOT EXISTS memory (
    namespace TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    PRIMARY KEY (namespace, key)
);
CREATE INDEX IF NOT EXISTS idx_memory_namespace ON memory (namespace);
SQL
    )" || {
        warn "memory-sqlite: schema init failed: $err" >&2 || true
        return 1
    }
    return 0
}

# ─── _sqlite3_quote — safely quote a string for SQLite ───────────────────────
_sqlite3_quote() {
    local val="$1"
    # SQLite string literals: single-quote, escape internal single-quotes by doubling
    printf "'%s'" "${val//\'/\'\'}"
}

# ─── memory_put <ns> <key> <value> ───────────────────────────────────────────
# exit 0: success; exit 1: backend error; exit 2: invalid args (empty key/ns)
memory_put() {
    local ns="$1" key="$2" value="$3"
    [[ -z "$ns" || -z "$key" ]] && return 2

    local db
    db="$(_memory_sqlite_db_path)"

    local q_ns q_key q_value
    q_ns="$(_sqlite3_quote "$ns")"
    q_key="$(_sqlite3_quote "$key")"
    q_value="$(_sqlite3_quote "$value")"

    sqlite3 "$db" \
        "INSERT OR REPLACE INTO memory (namespace, key, value, updated_at)
         VALUES ($q_ns, $q_key, $q_value, strftime('%s', 'now'));" 2>/dev/null || return 1
    return 0
}

# ─── memory_get <ns> <key> ───────────────────────────────────────────────────
# exit 0 always (empty stdout = miss); exit 1 on backend I/O error
memory_get() {
    local ns="$1" key="$2"
    [[ -z "$ns" || -z "$key" ]] && return 0

    local db
    db="$(_memory_sqlite_db_path)"
    [[ ! -f "$db" ]] && return 0

    local q_ns q_key
    q_ns="$(_sqlite3_quote "$ns")"
    q_key="$(_sqlite3_quote "$key")"

    local result
    result="$(sqlite3 "$db" \
        "SELECT value FROM memory WHERE namespace=$q_ns AND key=$q_key LIMIT 1;" 2>/dev/null)" || return 1
    printf '%s' "$result"
    return 0
}

# ─── memory_search <ns> <query> [--limit N] ──────────────────────────────────
# exit 0 always (no output = no matches); exit 1 on error
# Output: one <key>\t<value> per line; embedded newlines in value escaped as \n
memory_search() {
    local ns="$1" query="$2"
    local limit=""
    if [[ "${3:-}" == "--limit" && -n "${4:-}" ]]; then
        limit="$4"
    fi

    local db
    db="$(_memory_sqlite_db_path)"
    [[ ! -f "$db" ]] && return 0

    if [[ -n "$limit" && ! "$limit" =~ ^[0-9]+$ ]]; then
        printf 'memory_search: --limit value must be a non-negative integer\n' >&2
        return 2
    fi

    local q_ns q_like limit_clause
    q_ns="$(_sqlite3_quote "$ns")"
    # LIKE query: escape \, %, and _ in query, then wrap in %...%
    local escaped_query="${query//\\/\\\\}"
    escaped_query="${escaped_query//'%'/'\%'}"
    escaped_query="${escaped_query//'_'/'\_'}"
    q_like="$(_sqlite3_quote "%${escaped_query}%")"
    limit_clause=""
    [[ -n "$limit" ]] && limit_clause="LIMIT $limit"

    local rows
    rows="$(sqlite3 -separator $'\t' "$db" \
        "SELECT key, replace(value, char(10), '\n')
         FROM memory
         WHERE namespace=$q_ns
           AND (key LIKE $q_like ESCAPE '\\' OR value LIKE $q_like ESCAPE '\\')
         $limit_clause;" 2>/dev/null)" || return 1
    [[ -n "$rows" ]] && printf '%s\n' "$rows"
    return 0
}

# ─── memory_list_namespaces ───────────────────────────────────────────────────
# exit 0 always; exit 1 on error
memory_list_namespaces() {
    local db
    db="$(_memory_sqlite_db_path)"
    [[ ! -f "$db" ]] && return 0

    sqlite3 "$db" \
        "SELECT DISTINCT namespace FROM memory ORDER BY namespace;" 2>/dev/null || return 1
    return 0
}

# ─── memory_namespace_exists <ns> ────────────────────────────────────────────
# exit 0 if exists; exit 1 if absent (UNSAFE under set -e — use || true)
memory_namespace_exists() {
    local ns="$1"
    local db
    db="$(_memory_sqlite_db_path)"
    [[ ! -f "$db" ]] && return 1

    local q_ns
    q_ns="$(_sqlite3_quote "$ns")"
    local count
    count="$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM memory WHERE namespace=$q_ns LIMIT 1;" 2>/dev/null)" || return 1
    [[ "${count:-0}" -gt 0 ]] && return 0
    return 1
}

# ─── memory_namespace_clear <ns> ─────────────────────────────────────────────
# exit 0 success/idempotent; exit 1 on error
memory_namespace_clear() {
    local ns="$1"
    local db
    db="$(_memory_sqlite_db_path)"
    [[ ! -f "$db" ]] && return 0

    local q_ns
    q_ns="$(_sqlite3_quote "$ns")"
    sqlite3 "$db" \
        "DELETE FROM memory WHERE namespace=$q_ns;" 2>/dev/null || return 1
    return 0
}
