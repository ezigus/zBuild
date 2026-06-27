#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild event-bus — emit_event with dual SQLite + JSONL writers           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Single-writer JSONL (flock-guarded) + optional SQLite mirror for durability.
# Schema-as-warn: unknown event types log a warning but never block.
# Events from ARCHITECTURE.md §6.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_EVENT_BUS_LOADED:-}" ]] && return 0
_ZBUILD_EVENT_BUS_LOADED=1

_ZBUILD_EVENT_BUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT_FOR_EVENTS="$(cd "$_ZBUILD_EVENT_BUS_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/compat.sh
source "$_ZBUILD_ROOT_FOR_EVENTS/scripts/lib/compat.sh"

# ─── Locations ──────────────────────────────────────────────────────────────
ZBUILD_EVENTS_DIR="${ZBUILD_EVENTS_DIR:-${HOME}/.zbuild/state}"
ZBUILD_EVENTS_JSONL="${ZBUILD_EVENTS_JSONL:-${ZBUILD_EVENTS_DIR}/events.jsonl}"
ZBUILD_EVENTS_DB="${ZBUILD_EVENTS_DB:-${ZBUILD_EVENTS_DIR}/events.db}"
ZBUILD_EVENT_SCHEMA="${ZBUILD_EVENT_SCHEMA:-${_ZBUILD_ROOT_FOR_EVENTS}/config/event-schema.json}"

# ─── _eb_init — idempotent setup (dir, lockfile, SQLite schema) ─────────────
_eb_init() {
    mkdir -p "$ZBUILD_EVENTS_DIR"
    : > "${ZBUILD_EVENTS_JSONL}.lock" 2>/dev/null || true
    # SQLite is optional — only init if sqlite3 is present
    if command -v sqlite3 >/dev/null 2>&1 && [[ ! -f "$ZBUILD_EVENTS_DB" ]]; then
        local _eb_init_err
        _eb_init_err="$(sqlite3 "$ZBUILD_EVENTS_DB" <<'SQL' 2>&1
PRAGMA busy_timeout=2000;
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    run_id TEXT,
    issue INTEGER,
    type TEXT NOT NULL,
    plugin TEXT,
    kind TEXT,
    payload TEXT,
    schema_version INTEGER DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_run_id ON events(run_id);
SQL
        )" || { [[ -n "$_eb_init_err" ]] && echo "[event-bus] WARN: sqlite3 failed: $_eb_init_err" >&2; }
    fi
}

# ─── _eb_known_type — schema-as-warn check ──────────────────────────────────
# Returns 0 if known, 1 if unknown (but never blocks emission).
_eb_known_type() {
    local type="$1"
    if [[ ! -f "$ZBUILD_EVENT_SCHEMA" ]]; then
        return 0  # No schema yet; permissive.
    fi
    # Simple grep against the schema's known_types list.
    if jq -e --arg t "$type" '.known_types | index($t)' "$ZBUILD_EVENT_SCHEMA" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# _eb_strip_ansi — strip CSI + bare-ESC sequences from a string before JSONL emission.
# Ported from legacy/scripts/lib/helpers.sh:431-437; two-pass form mirrors _stage_io_strip_ansi.
# LC_ALL=C so sed processes raw bytes without aborting on non-UTF-8 sequences (issue #830).
_eb_strip_ansi() {
    printf '%s' "$1" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g'
}

# ─── eb_emit_event — single source of truth for events ──────────────────────
# Usage:
#   eb_emit_event <type> [key1=val1] [key2=val2] ...
#
# Standard envelope fields are picked up from env vars:
#   ZBUILD_RUN_ID, ZBUILD_ISSUE, ZBUILD_PLUGIN, ZBUILD_PLUGIN_KIND
eb_emit_event() {
    local type="$1"; shift
    _eb_init

    if ! _eb_known_type "$type"; then
        # Schema-as-warn: always log, never block.
        echo "[event-bus] WARN: unknown event type '$type' (run_id=${ZBUILD_RUN_ID:-})" >&2
    fi

    # Build payload from key=val args
    local payload="{}"
    local key val
    for arg in "$@"; do
        key="${arg%%=*}"
        val="$(_eb_strip_ansi "${arg#*=}")"
        payload="$(echo "$payload" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')"
    done

    # ISO 8601 timestamp with milliseconds
    local ts
    if [[ "$ZBUILD_PLATFORM" == "macos" ]]; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    else
        ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    fi

    local run_id; run_id="$(_eb_strip_ansi "${ZBUILD_RUN_ID:-}")"
    local issue="${ZBUILD_ISSUE:-0}"
    local plugin; plugin="$(_eb_strip_ansi "${ZBUILD_PLUGIN:-}")"
    local kind; kind="$(_eb_strip_ansi "${ZBUILD_PLUGIN_KIND:-}")"

    # Validate-or-cast $issue to a non-negative integer. Coming from env, an
    # unsanitized string here would break the SQL INSERT below ($issue is
    # interpolated unquoted because the column is INTEGER).
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
        issue=0
    fi

    local event_json
    event_json="$(jq -cn \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --argjson issue "$issue" \
        --arg type "$type" \
        --arg plugin "$plugin" \
        --arg kind "$kind" \
        --argjson data "$payload" \
        '{ts: $ts, run_id: $run_id, issue: $issue, type: $type, plugin: $plugin, kind: $kind, data: $data, schema_version: 1}')"

    # Single-writer JSONL via flock
    if zbuild_has_flock; then
        (
            flock -w 5 9 || exit 1
            echo "$event_json" >> "$ZBUILD_EVENTS_JSONL"
        ) 9>"${ZBUILD_EVENTS_JSONL}.lock"
    else
        # Best-effort fallback
        echo "$event_json" >> "$ZBUILD_EVENTS_JSONL"
    fi

    # SQLite mirror (optional, fire-and-forget).
    # Escape every string field — previously only $payload was escaped, so a
    # plugin emitting e.g. ZBUILD_PLUGIN_KIND="x'); DROP TABLE events;--"
    # could corrupt the event store. $issue is validated as integer above
    # and interpolated unquoted (INTEGER column).
    if command -v sqlite3 >/dev/null 2>&1; then
        local _ts_esc _rid_esc _type_esc _plugin_esc _kind_esc _payload_esc
        _ts_esc="$(_eb_sql_escape "$ts")"
        _rid_esc="$(_eb_sql_escape "$run_id")"
        _type_esc="$(_eb_sql_escape "$type")"
        _plugin_esc="$(_eb_sql_escape "$plugin")"
        _kind_esc="$(_eb_sql_escape "$kind")"
        _payload_esc="$(_eb_sql_escape "$payload")"
        local _eb_emit_err
        _eb_emit_err="$(sqlite3 "$ZBUILD_EVENTS_DB" <<SQL 2>&1
PRAGMA busy_timeout=2000;
INSERT INTO events (ts, run_id, issue, type, plugin, kind, payload, schema_version)
VALUES ('$_ts_esc', '$_rid_esc', $issue, '$_type_esc', '$_plugin_esc', '$_kind_esc', '$_payload_esc', 1);
SQL
        )" || { [[ -n "$_eb_emit_err" ]] && echo "[event-bus] WARN: sqlite3 failed: $_eb_emit_err" >&2; }
    fi
}

# _eb_sql_escape: double single-quotes for SQLite single-quoted string literals.
# Single source of truth; used for every string field in the INSERT above.
# Uses sed because bash parameter expansion ${s//\'/\'\'} inside double
# quotes treats \' as literal backslash+quote (Copilot caught this on #278).
_eb_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# ─── eb_query_events — minimal read API ─────────────────────────────────────
# Usage: eb_query_events [type_filter] [limit]
eb_query_events() {
    local type_filter="${1:-}"
    local limit="${2:-100}"
    if [[ ! -f "$ZBUILD_EVENTS_JSONL" ]]; then
        return 0
    fi
    if [[ -n "$type_filter" ]]; then
        jq -c --arg t "$type_filter" 'select(.type == $t)' "$ZBUILD_EVENTS_JSONL" | tail -"$limit"
    else
        tail -"$limit" "$ZBUILD_EVENTS_JSONL"
    fi
}

# ─── Override emit_event from helpers.sh ────────────────────────────────────
# The placeholder emit_event in scripts/lib/helpers.sh delegates here when
# the event-bus is sourced. Just redefine the function.
emit_event() {
    eb_emit_event "$@"
}
