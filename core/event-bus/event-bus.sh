#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild event-bus — emit_event, one flock-guarded JSONL writer            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Single-writer JSONL (flock-guarded). events.jsonl is the only record and the
# only read path; the SQLite mirror it once fed had no reader and was removed
# (ADR-065 §5, 2026-10-24).
# Schema-as-warn: unknown event types log a warning but never block.
# Events from ARCHITECTURE.md §6.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_EVENT_BUS_LOADED:-}" ]] && return 0
_ZBUILD_EVENT_BUS_LOADED=1

_ZBUILD_EVENT_BUS_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)"
_ZBUILD_ROOT_FOR_EVENTS="$(cd "$_ZBUILD_EVENT_BUS_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/compat.sh
source "$_ZBUILD_ROOT_FOR_EVENTS/scripts/lib/compat.sh"
# The known-type set (#1717): engine config + every manifest's provides.events.
# shellcheck source=known-types.sh
source "$_ZBUILD_EVENT_BUS_DIR/known-types.sh"

# ─── Locations ──────────────────────────────────────────────────────────────
# An engine run (core/pipeline/runner.sh) ALWAYS pins these to its per-run dir
# (runs/<run_id>/, #887). An UNPINNED caller — an ad-hoc/test invocation that
# sources the event-bus directly — must NOT accumulate into the shared
# ${HOME}/.zbuild/state/events.{jsonl,db}: that store grows unbounded across
# ad-hoc invocations and a stale events.jsonl.lock left by a killed run can
# hang a later run's `flock -w` (#run-hygiene). Resolve the defaults coherently:
#   1. Nothing pinned  → ephemeral, process-scoped dir under the DATA ROOT,
#      never the durable shared global default and never ${TMPDIR}. ADR-059 §1
#      makes the path the keying: a reclaimer deletes a `runs/<id>/` or an
#      `issues/<N>/` and the scope follows from where it sits, so a ${TMPDIR}
#      default is outside every reclaimable path by construction — which is why
#      cleanup.sh needed a ZBUILD_TMPDIR_PATTERNS scanner to sweep ~2300 of
#      these (#2004). ADR-023/ADR-059 §1 also reject ${TMPDIR} for durable
#      state: on macOS its entries can vanish mid-run (#1571, #1609/#1611).
#   2. Only JSONL pinned → derive the dir (hence the lock) from it, so a
#      pinned jsonl never leaks a lock back to the global default (the test
#      harness pins only ZBUILD_EVENTS_JSONL).
# An explicit ZBUILD_EVENTS_DIR always wins.
if [[ -z "${ZBUILD_EVENTS_DIR:-}${ZBUILD_EVENTS_JSONL:-}" ]]; then
    # Same precedence as zbuild_layout_data_root (core/state/layout.sh); inlined
    # because the event bus deliberately sources almost nothing.
    ZBUILD_EVENTS_DIR="${ZBUILD_DATA_ROOT:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild}}/ephemeral-events/$$"
elif [[ -z "${ZBUILD_EVENTS_DIR:-}" && -n "${ZBUILD_EVENTS_JSONL:-}" ]]; then
    ZBUILD_EVENTS_DIR="$(dirname "$ZBUILD_EVENTS_JSONL")"
fi
ZBUILD_EVENTS_DIR="${ZBUILD_EVENTS_DIR:-${ZBUILD_STATE_ROOT:-${HOME}/.zbuild/state}}"
ZBUILD_EVENTS_JSONL="${ZBUILD_EVENTS_JSONL:-${ZBUILD_EVENTS_DIR}/events.jsonl}"
ZBUILD_EVENT_SCHEMA="${ZBUILD_EVENT_SCHEMA:-${_ZBUILD_ROOT_FOR_EVENTS}/config/event-schema.json}"

# ─── _eb_init — idempotent setup (dir, lockfile) ─────────────────────────────
_eb_init() {
    [[ -d "$ZBUILD_EVENTS_DIR" ]] || mkdir -p "$ZBUILD_EVENTS_DIR"
    : > "${ZBUILD_EVENTS_JSONL}.lock" 2>/dev/null || true
}

# ─── _eb_known_type — schema-as-warn check ──────────────────────────────────
# Returns 0 if known, 1 if unknown (but never blocks emission).
#
# #1717: this used to fork `jq` against ZBUILD_EVENT_SCHEMA on EVERY emit. The
# known set now also spans every plugin manifest, so per-emit reading would have
# multiplied that fork by plugin count. Composition happens once (per process,
# and once per RUN via the file cache in known-types.sh); the check itself is an
# associative-array lookup and forks nothing.
_eb_known_type() {
    eb_known_types_has "$1"
}

# _eb_strip_ansi — strip CSI + bare-ESC sequences from a string before JSONL emission.
# Ported from legacy-DoNotUse/scripts/lib/helpers.sh:431-437; two-pass form mirrors _stage_io_strip_ansi.
# LC_ALL=C so sed processes raw bytes without aborting on non-UTF-8 sequences (issue #830).
# No ESC byte → nothing to strip, and no fork: this runs for every value of every
# event, and a sed per call was the single largest exec site in a run (ADR-065).
_eb_strip_ansi() {
    [[ "$1" == *$'\x1b'* ]] || { printf '%s' "$1"; return 0; }
    printf '%s' "$1" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g'
}

# _eb_strip_ansi_v <var> <value>: the same, into <var>, with no subshell when
# the value holds no ESC (#1806 — the envelope and every field took one each).
_eb_strip_ansi_v() {
    if [[ "$2" == *$'\x1b'* ]]; then
        printf -v "$1" '%s' "$(_eb_strip_ansi "$2")"
    else
        printf -v "$1" '%s' "$2"
    fi
}

# _eb_now_iso_v <var>: UTC, with milliseconds, from the shell's own clock (#1806).
# No `date` process, and no reading of ZBUILD_PLATFORM: a map work unit exports
# its TARGET platform there (ADR-009 §6), which is not the host the clock is on.
# EPOCHREALTIME's separator follows the locale, so both . and , are accepted.
_eb_now_iso_v() {
    local _er="$EPOCHREALTIME" _s _f _iso
    _s="${_er%[.,]*}"; _f="${_er#*[.,]}000"
    TZ=UTC0 printf -v _iso '%(%Y-%m-%dT%H:%M:%S)T' "$_s"
    printf -v "$1" '%s.%sZ' "$_iso" "${_f:0:3}"
}

# _eb_json_str_v <var> <value>: <value> as a JSON string, spelled as jq spells
# it (ADR-065 §5). Plain ASCII only — the caller sends anything else to jq.
_eb_json_str_v() {
    local LC_ALL=C _s="$2" _c _e
    local -i _i
    _s="${_s//\\/\\\\}"; _s="${_s//\"/\\\"}"
    if [[ "$_s" == *[$'\x01'-$'\x1f'$'\x7f']* ]]; then
        _s="${_s//$'\n'/\\n}"; _s="${_s//$'\t'/\\t}"; _s="${_s//$'\r'/\\r}"
        _s="${_s//$'\b'/\\b}"; _s="${_s//$'\f'/\\f}"
        for _i in {1..31} 127; do
            printf -v _c '%02x' "$_i"; printf -v _c "\\x$_c"
            [[ "$_s" == *"$_c"* ]] || continue
            printf -v _e '\\u%04x' "$_i"
            _s="${_s//"$_c"/"$_e"}"
        done
    fi
    printf -v "$1" '"%s"' "$_s"
}

# _eb_ascii <string>: true when every byte is below 0x80. A class, not a byte
# range, so an xtrace of this line stays plain text (fork-census reads it).
_eb_ascii() {
    local LC_ALL=C
    [[ "$1" != *[![:ascii:]]* ]]
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

    # Build payload from key=val args. plugin/kind are also captured here as a
    # fallback for the envelope (#1705): emitters outside plugin_hook_call's
    # dynamic extent — the contract checker, the tamper check — never see the
    # exported ZBUILD_PLUGIN context, and left the envelope's advertised
    # .plugin/.kind empty. Captured in this existing loop so the hot path gains
    # no subprocess, and applied below only when the exported context is absent.
    # #1806: the fields travel to the ONE jq below as numbered --arg pairs
    # (_k0/_v0, …); it builds .data (a later duplicate key wins, as before) with
    # the envelope. An option argument is never read as an option, so a value
    # like "-n" stays a value — a positional list after --args would not.
    local key val
    local _data_plugin="" _data_kind=""
    local -a _pairs=() _keys=() _vals=()
    local -i _n=0
    for arg in "$@"; do
        key="${arg%%=*}"
        _eb_strip_ansi_v val "${arg#*=}"
        case "$key" in
            plugin) _data_plugin="$val" ;;
            kind)   _data_kind="$val" ;;
        esac
        _pairs+=(--arg "_k$_n" "$key" --arg "_v$_n" "$val")
        _keys+=("$key"); _vals+=("$val")
        _n+=1
    done

    local ts; _eb_now_iso_v ts

    local run_id; _eb_strip_ansi_v run_id "${ZBUILD_RUN_ID:-}"
    local issue="${ZBUILD_ISSUE:-0}"
    local plugin; _eb_strip_ansi_v plugin "${ZBUILD_PLUGIN:-}"
    local kind; _eb_strip_ansi_v kind "${ZBUILD_PLUGIN_KIND:-}"
    # Fall back to the payload's own plugin/kind so the envelope is populated
    # for every emitter, not only those dispatched through plugin_hook_call.
    # Applied before the SQLite insert too, so both stores agree.
    if [[ -z "$plugin" ]]; then plugin="$_data_plugin"; fi
    if [[ -z "$kind" ]]; then kind="$_data_kind"; fi
    # ADR-004 / ADR-039 §3: stamp the active stage onto the envelope so the
    # router's C6 precondition can be scoped PER-STAGE. Parallel-group members
    # (parallel-orchestrator.sh) each export ZBUILD_CURRENT_STAGE inside their
    # own subshell, so a sibling member's `plugin.run.start` can no longer
    # become the most-recent event that satisfies/clobbers THIS member's
    # `redaction.applied` check. Present ONLY when a stage is active — stage-less
    # emits (pipeline.start, template load, bootstrap) keep the canonical 8-key
    # envelope, so C6 falls back to the run-level last-event check for them.
    local stage; _eb_strip_ansi_v stage "${ZBUILD_CURRENT_STAGE:-}"
    # #2131 (ADR-064): the stage-io seq label (`6.1.3` = runner cardinal ·
    # cycle iteration · member position) rides the envelope by the same rule
    # as `stage` — present only while a label is exported. It was rendered
    # into the banner and persisted nowhere, so the run-status comment had no
    # key to pair a stage's start with its end. Validated, not ANSI-stripped:
    # the label is engine-generated digits and dots, and anything else is an
    # upstream fault that must not become a row key downstream.
    local seq="${ZBUILD_STAGE_IO_SEQ_LABEL:-}"
    [[ "$seq" =~ ^[0-9]+(\.[0-9]+)*$ ]] || seq=""
    # #1706 (ADR-054 §3.1): a map member's own name rides the envelope only
    # when it differs from the stage, so every other envelope is unchanged.
    local unit="${ZBUILD_UNIT:-}"
    [[ "$unit" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){0,2}$ && "$unit" != "$stage" ]] || unit=""

    # Validate-or-cast $issue to a non-negative integer. Coming from env, an
    # non-number here would make jq's --argjson reject the whole event.
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
        issue=0
    fi

    # One compact line out: the event. Plain ASCII — nearly every event — is
    # written by the shell, spelled exactly as jq would (ADR-065 §5); any other
    # byte, or an issue too long for shell arithmetic, goes to jq. An event jq
    # cannot build is dropped, never fatal: this runs bare under `set -e`
    # everywhere (see the closing `return 0`).
    local event_json="" _all
    printf -v _all '%s\034' "$type" "$run_id" "$plugin" "$kind" "$stage" "$unit" "${_keys[@]}" "${_vals[@]}"
    if [[ ${#issue} -le 15 ]] && _eb_ascii "$_all"; then
        local _j _data=""
        local -i _x
        # A later duplicate key keeps the first one's place and gives its value,
        # as jq's `add`. One pass to find each key's last value, one to write:
        # comparing every pair grew with the square of the key count.
        local -A _last=() _done=()
        for (( _x = 0; _x < _n; _x++ )); do _last["${_keys[_x]}"]=$_x; done
        for (( _x = 0; _x < _n; _x++ )); do
            [[ -n "${_done["${_keys[_x]}"]:-}" ]] && continue
            _done["${_keys[_x]}"]=1
            _eb_json_str_v _j "${_keys[_x]}"; _data+="${_data:+,}$_j:"
            _eb_json_str_v _j "${_vals[_last["${_keys[_x]}"]]}"; _data+="$_j"
        done
        event_json="{\"ts\":\"$ts\""
        _eb_json_str_v _j "$run_id"; event_json+=",\"run_id\":$_j,\"issue\":$(( 10#$issue ))"
        _eb_json_str_v _j "$type";   event_json+=",\"type\":$_j"
        _eb_json_str_v _j "$plugin"; event_json+=",\"plugin\":$_j"
        _eb_json_str_v _j "$kind";   event_json+=",\"kind\":$_j,\"data\":{$_data},\"schema_version\":1"
        if [[ -n "$stage" ]]; then _eb_json_str_v _j "$stage"; event_json+=",\"stage\":$_j"; fi
        [[ -n "$seq" ]] && event_json+=",\"seq\":\"$seq\""
        if [[ -n "$unit" ]]; then _eb_json_str_v _j "$unit"; event_json+=",\"unit\":$_j"; fi
        event_json+="}"
    fi
    [[ -n "$event_json" ]] || event_json="$(jq -cn \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --argjson issue "$issue" \
        --arg type "$type" \
        --arg plugin "$plugin" \
        --arg kind "$kind" \
        --arg stage "$stage" \
        --arg seq "$seq" \
        --arg unit "$unit" \
        --argjson _n "$_n" \
        "${_pairs[@]}" \
        '$ARGS.named as $a
         | ([range(0; $_n) | {($a["_k\(.)"]): $a["_v\(.)"]}] | add // {}) as $data
         | ({ts: $ts, run_id: $run_id, issue: $issue, type: $type, plugin: $plugin, kind: $kind, data: $data, schema_version: 1}
            + (if $stage != "" then {stage: $stage} else {} end)
            + (if $seq != "" then {seq: $seq} else {} end)
            + (if $unit != "" then {unit: $unit} else {} end))')" || return 0

    # Single-writer JSONL via flock. A brace group, not a subshell: the lock is
    # on fd 9's open file, held until the group closes it, and no shell is copied.
    # `|| true` on each: a lock or file that cannot be opened is a redirect
    # error, which `set -e` does not forgive, and an emit must never end its
    # caller (#1153).
    if zbuild_has_flock; then
        {
            flock -w 5 9 && echo "$event_json" >> "$ZBUILD_EVENTS_JSONL"
        } 9>"${ZBUILD_EVENTS_JSONL}.lock" || true
    else
        # Best-effort fallback
        { echo "$event_json" >> "$ZBUILD_EVENTS_JSONL"; } || true
    fi

    # Fire-and-forget: emit MUST never fail its caller — eb_emit_event is called
    # bare under `set -e` throughout the pipeline, so a flock-block rc must not
    # become this function's rc (#1153).
    return 0
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
