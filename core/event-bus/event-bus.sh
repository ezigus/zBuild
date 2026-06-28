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

# ─── _eb_mirror_enabled — is the optional SQLite mirror active? ─────────────
# True only when sqlite3 is installed AND a real DB path is configured.
# ZBUILD_EVENTS_DB=/dev/null is the "JSONL only, no mirror" sentinel (parity
# fixtures use it); its `.lock` path is unwritable, so the mirror — including
# the dedicated lock — must be skipped entirely, not just fail-soft (#1153).
_eb_mirror_enabled() {
    [[ "$ZBUILD_EVENTS_DB" != "/dev/null" ]] && command -v sqlite3 >/dev/null 2>&1
}

# ─── _eb_init — idempotent setup (dir, lockfile, SQLite schema) ─────────────
_eb_init() {
    mkdir -p "$ZBUILD_EVENTS_DIR"
    : > "${ZBUILD_EVENTS_JSONL}.lock" 2>/dev/null || true
    # SQLite mirror (optional, best-effort) — set up the dedicated mirror lock
    # (SEPARATE from the jsonl lock, so a slow mirror never blocks the
    # authoritative append, #1153) and schema only when the mirror is enabled.
    if _eb_mirror_enabled; then
        : > "${ZBUILD_EVENTS_DB}.lock" 2>/dev/null || true
      if [[ ! -f "$ZBUILD_EVENTS_DB" ]]; then
        local _eb_init_err
        # busy_timeout via -cmd (no stdout echo, unlike PRAGMA busy_timeout=N).
        # Concurrent mirror writes are serialized by flock (ADR-005) in
        # eb_emit_event — flock is the deterministic primitive zbuild requires,
        # whereas sqlite3 is optional. The timeout is just a cheap safety net
        # for a stale lock holder (#1059 chose 2000ms). The mirror stays in the
        # default journal mode: no concurrent reader of events.db exists (jsonl
        # is the only read path, via eb_query_events).
        _eb_init_err="$(sqlite3 -cmd ".timeout 2000" "$ZBUILD_EVENTS_DB" <<'SQL' 2>&1
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
    # and interpolated unquoted (INTEGER column). Skipped (incl. the flock on
    # the dedicated lock) when the mirror is disabled — e.g. ZBUILD_EVENTS_DB=
    # /dev/null, whose .lock redirect would otherwise fail the emit (#1153).
    if _eb_mirror_enabled; then
        local _ts_esc _rid_esc _type_esc _plugin_esc _kind_esc _payload_esc
        _ts_esc="$(_eb_sql_escape "$ts")"
        _rid_esc="$(_eb_sql_escape "$run_id")"
        _type_esc="$(_eb_sql_escape "$type")"
        _plugin_esc="$(_eb_sql_escape "$plugin")"
        _kind_esc="$(_eb_sql_escape "$kind")"
        _payload_esc="$(_eb_sql_escape "$payload")"
        local _eb_insert_sql
        _eb_insert_sql="INSERT INTO events (ts, run_id, issue, type, plugin, kind, payload, schema_version) VALUES ('$_ts_esc', '$_rid_esc', $issue, '$_type_esc', '$_plugin_esc', '$_kind_esc', '$_payload_esc', 1);"
        # Serialize the mirror INSERT with flock on the DEDICATED db lock (NOT
        # the jsonl lock): flock is the deterministic primitive zbuild requires
        # (ADR-005), so concurrent emitters (#1131) no longer collide on the
        # mirror write. Separate lock ⇒ the best-effort mirror can never block
        # the authoritative jsonl append above. flock-timeout ⇒ drop the mirror
        # write (exit 0), never fail the emit (#1153).
        if zbuild_has_flock; then
            (
                flock -w 5 9 || exit 0
                _eb_mirror_insert "$_eb_insert_sql"
            ) 9>"${ZBUILD_EVENTS_DB}.lock"
        else
            _eb_mirror_insert "$_eb_insert_sql"
        fi
    fi

    # Fire-and-forget: emit MUST never fail its caller — eb_emit_event is called
    # bare under `set -e` throughout the pipeline, so the best-effort mirror's
    # rc (or a flock-block rc) must not become this function's rc. Without this
    # the trailing mirror block's exit code propagated out and aborted stages
    # (build:fail / test:error) when the INSERT returned non-zero (#1153 fix).
    return 0
}

# _eb_mirror_insert — run one best-effort mirror INSERT; warn (never fail) on
# sqlite3 error. Caller serializes via flock. busy_timeout via -cmd (no stdout,
# unlike PRAGMA busy_timeout=N which echoes the value) is a safety net for a
# stale lock holder (#1059 chose the 2000ms window).
_eb_mirror_insert() {
    local _eb_emit_err
    _eb_emit_err="$(sqlite3 -cmd ".timeout 2000" "$ZBUILD_EVENTS_DB" "$1" 2>&1)" \
        || { [[ -n "$_eb_emit_err" ]] && echo "[event-bus] WARN: sqlite3 failed: $_eb_emit_err" >&2; }
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
