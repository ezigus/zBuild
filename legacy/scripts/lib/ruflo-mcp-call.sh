#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  ruflo-mcp-call — Bash wrapper for the ruflo unix-socket bridge          ║
# ║                                                                           ║
# ║  Provides a fail-open bash API for talking to scripts/lib/ruflo-bridge.   ║
# ║  All public entry points return 0 from "bridge unavailable" so callers    ║
# ║  can branch cleanly to a legacy ruflo subprocess fallback. Only wire      ║
# ║  errors (bridge said success:false, jq/nc missing, malformed response)    ║
# ║  return 1.                                                                ║
# ║                                                                           ║
# ║  Public functions:                                                        ║
# ║    ruflo_mcp_call <tool> [key=val ...]   stdout: response JSON            ║
# ║    ruflo_bridge_available                exit 0 iff socket responds        ║
# ║    _ruflo_bridge_start                   spawn bridge, wait until ready   ║
# ║    _ruflo_bridge_stop                    SIGTERM bridge from PID file     ║
# ║                                                                           ║
# ║  Env overrides:                                                           ║
# ║    RUFLO_BRIDGE_SOCK     unix socket path (default ~/.shipwright/...)     ║
# ║    RUFLO_BRIDGE_TIMEOUT  per-call nc timeout in seconds (default 5)       ║
# ║    RUFLO_BRIDGE_SCRIPT   path to ruflo-bridge.mjs (default sibling file)  ║
# ║    RUFLO_BRIDGE_NODE     node binary path (default `node` on PATH)        ║
# ║                                                                           ║
# ║  Bash 3.2 compatible — no associative arrays, no `${var,,}`, no readarray.║
# ╚═══════════════════════════════════════════════════════════════════════════╝

VERSION="3.6.1"

# ─── Double-source guard ────────────────────────────────────────────────────
# Caller may pre-export RUFLO_BRIDGE_SOCK to point at a custom path; the guard
# ensures re-sourcing this file does not clobber that override.
[[ -n "${_RUFLO_MCP_CALL_LOADED:-}" ]] && return 0
_RUFLO_MCP_CALL_LOADED=1

# ─── Defaults — preserve any inherited values ───────────────────────────────
RUFLO_BRIDGE_SOCK="${RUFLO_BRIDGE_SOCK:-$HOME/.shipwright/ruflo-bridge.sock}"
RUFLO_BRIDGE_TIMEOUT="${RUFLO_BRIDGE_TIMEOUT:-5}"
RUFLO_BRIDGE_NODE="${RUFLO_BRIDGE_NODE:-node}"
# Resolve sibling script path when not pre-set. Use a subshell for `cd` so the
# caller's working directory is never mutated (per repo convention).
if [[ -z "${RUFLO_BRIDGE_SCRIPT:-}" ]]; then
    RUFLO_BRIDGE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ruflo-bridge.mjs"
fi
# Maximum tenths of a second to wait for the bridge to come up after spawn.
# 30 = 3 seconds. Bounded sleep is a failsafe, not a polling primitive
# (per core/testing-baseline.md).
RUFLO_BRIDGE_START_TIMEOUT_DECIS="${RUFLO_BRIDGE_START_TIMEOUT_DECIS:-30}"

export RUFLO_BRIDGE_SOCK RUFLO_BRIDGE_TIMEOUT RUFLO_BRIDGE_SCRIPT \
       RUFLO_BRIDGE_NODE RUFLO_BRIDGE_START_TIMEOUT_DECIS

# ─── _ruflo_bridge_log — stderr only, prefixed for grep-ability ─────────────
_ruflo_bridge_log() {
    printf 'ruflo-mcp-call: %s\n' "$*" >&2
}

# ─── ruflo_bridge_available — fast health check ─────────────────────────────
# Returns 0 iff: socket file exists, nc is on PATH, ping returns success:true.
# Bounded by `nc -w 1` so this never blocks the caller for more than ~1s.
ruflo_bridge_available() {
    [[ -S "$RUFLO_BRIDGE_SOCK" ]] || return 1
    command -v nc >/dev/null 2>&1 || return 1
    local resp
    resp=$(printf '{"tool":"ping","args":{}}\n' \
        | nc -U -w 1 "$RUFLO_BRIDGE_SOCK" 2>/dev/null) || return 1
    case "$resp" in
        *'"success":true'*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── ruflo_mcp_call — make one bridge request ───────────────────────────────
# Usage: ruflo_mcp_call <tool> [key=val ...]
# Stdout: the raw response JSON line (one line, no trailing newline beyond it).
# Returns:
#   0   success:true response received
#   1   any failure (jq/nc missing, transport error, success:false response)
ruflo_mcp_call() {
    if [[ $# -lt 1 ]]; then
        _ruflo_bridge_log "tool name required"
        return 1
    fi
    local tool="$1"; shift

    if ! command -v jq >/dev/null 2>&1; then
        _ruflo_bridge_log "jq required but not on PATH"
        return 1
    fi
    if ! command -v nc >/dev/null 2>&1; then
        _ruflo_bridge_log "nc required but not on PATH"
        return 1
    fi

    # Build args object using jq --arg (injection-safe — never string concat).
    # Each key=value pair is folded into the object via jq's `+` operator so
    # embedded quotes, backslashes, newlines, ${VAR} substrings round-trip
    # verbatim in the args.value field.
    local args='{}' kv k v
    for kv in "$@"; do
        # Split on first '=' only so values may themselves contain '='.
        if [[ "$kv" != *"="* ]]; then
            _ruflo_bridge_log "argument '$kv' missing '=' separator"
            return 1
        fi
        k="${kv%%=*}"
        v="${kv#*=}"
        if [[ -z "$k" ]]; then
            _ruflo_bridge_log "argument '$kv' has empty key"
            return 1
        fi
        args=$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$args") \
            || { _ruflo_bridge_log "jq failed building args"; return 1; }
    done

    local req
    req=$(jq -c -n --arg t "$tool" --argjson a "$args" \
        '{tool:$t, args:$a}') \
        || { _ruflo_bridge_log "jq failed building request"; return 1; }

    local resp
    # `nc -w` is the bounded transport timeout. -N closes the socket after
    # stdin EOF on netcat-openbsd; we omit it because not every nc variant
    # supports it (BSD nc on macOS does, GNU netcat does not). The bridge
    # closes the connection after writing one response line, which makes
    # nc exit on its own.
    resp=$(printf '%s\n' "$req" \
        | nc -U -w "$RUFLO_BRIDGE_TIMEOUT" "$RUFLO_BRIDGE_SOCK" 2>/dev/null) \
        || { _ruflo_bridge_log "nc transport failed (socket=$RUFLO_BRIDGE_SOCK)"; return 1; }

    if [[ -z "$resp" ]]; then
        _ruflo_bridge_log "empty response from bridge"
        return 1
    fi

    printf '%s\n' "$resp"
    case "$resp" in
        *'"success":true'*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── _ruflo_bridge_start — spawn the bridge and wait for readiness ──────────
# Idempotent: if the bridge is already up (per `ruflo_bridge_available`),
# returns 0 immediately without spawning a duplicate.
# Returns 0 iff bridge is responsive within RUFLO_BRIDGE_START_TIMEOUT_DECIS.
_ruflo_bridge_start() {
    if ruflo_bridge_available; then
        return 0
    fi
    if ! command -v "$RUFLO_BRIDGE_NODE" >/dev/null 2>&1; then
        _ruflo_bridge_log "node not on PATH (RUFLO_BRIDGE_NODE=$RUFLO_BRIDGE_NODE)"
        return 1
    fi
    if [[ ! -f "$RUFLO_BRIDGE_SCRIPT" ]]; then
        _ruflo_bridge_log "bridge script missing: $RUFLO_BRIDGE_SCRIPT"
        return 1
    fi

    # Ensure parent dir exists (mkdir -p is idempotent).
    local sock_dir
    sock_dir="$(dirname "$RUFLO_BRIDGE_SOCK")"
    mkdir -p "$sock_dir" 2>/dev/null || true

    # Spawn detached so the bridge survives the caller's shell exit.
    # nohup + & + redirected stdio keeps the bridge from holding our terminal.
    nohup "$RUFLO_BRIDGE_NODE" "$RUFLO_BRIDGE_SCRIPT" \
        </dev/null >/dev/null 2>&1 &
    local spawned_pid=$!

    # Bounded poll: 100ms increments, capped by RUFLO_BRIDGE_START_TIMEOUT_DECIS.
    # Justified failsafe per core/testing-baseline.md — not a synchronization
    # primitive, just an upper bound on the start-up race window.
    local waited=0
    while [[ $waited -lt $RUFLO_BRIDGE_START_TIMEOUT_DECIS ]]; do
        if ruflo_bridge_available; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Startup failed — try to clean up the orphaned process so we don't leak.
    kill -TERM "$spawned_pid" 2>/dev/null || true
    _ruflo_bridge_log "bridge did not become ready within $((RUFLO_BRIDGE_START_TIMEOUT_DECIS / 10))s"
    return 1
}

# ─── _ruflo_bridge_stop — terminate the bridge via PID file ─────────────────
# Always returns 0 (idempotent). Bridge's SIGTERM handler unlinks the socket
# and PID file; we still attempt direct unlink as a backstop in case the
# process is already gone but the socket file lingered.
_ruflo_bridge_stop() {
    local pidfile="${RUFLO_BRIDGE_SOCK}.pid"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null) || pid=""
        if [[ -n "$pid" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            # Best-effort wait for clean shutdown (max 1s in 100ms increments).
            local waited=0
            while [[ $waited -lt 10 ]]; do
                if ! kill -0 "$pid" 2>/dev/null; then break; fi
                sleep 0.1
                waited=$((waited + 1))
            done
        fi
    fi
    # Backstop cleanup — covers the case where the bridge crashed without
    # running its signal handler, leaving stale files behind.
    [[ -e "$RUFLO_BRIDGE_SOCK" ]] && rm -f "$RUFLO_BRIDGE_SOCK" 2>/dev/null
    [[ -f "$pidfile" ]] && rm -f "$pidfile" 2>/dev/null
    return 0
}
