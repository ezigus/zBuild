#!/usr/bin/env bash
# proc-utils.sh — shared process cleanup primitives
# Bash 3.2 compatible — no associative arrays, no extended glob, no readarray.
# Sourced by sw-pipeline.sh, sw-loop.sh, sw-dashboard.sh, sw-stream.sh,
# sw-webhook.sh, sw-incident.sh, and ruflo-adapter.sh.
set -euo pipefail

VERSION_PROC_UTILS="1.0.0"

# ─── _kill_process_tree ───────────────────────────────────────────────────────
# Send SIGNAL to PID and all its descendants.
# Collects the full descendant list via BFS *before* killing anything, so that
# re-parenting (child → init) cannot cause grandchildren to escape the sweep.
# Bash 3.2 compatible — no associative arrays, no extended syntax.
#
# Usage: _kill_process_tree SIGNAL PID
_kill_process_tree() {
    local sig="$1"
    local root="$2"
    local all_pids frontier new_frontier p c children

    if ! command -v pgrep >/dev/null 2>&1; then
        kill "-$sig" "$root" 2>/dev/null || true
        return
    fi

    # BFS: collect every descendant before touching any of them.
    all_pids=""
    frontier="$root"
    while [[ -n "$frontier" ]]; do
        new_frontier=""
        for p in $frontier; do
            children=$(pgrep -P "$p" 2>/dev/null || true)
            for c in $children; do
                all_pids="${all_pids}${all_pids:+ }$c"
                new_frontier="${new_frontier}${new_frontier:+ }$c"
            done
        done
        frontier="$new_frontier"
    done

    # Kill all descendants (collected before any were killed), then root last.
    for p in $all_pids; do
        kill "-$sig" "$p" 2>/dev/null || true
    done
    kill "-$sig" "$root" 2>/dev/null || true
}

# ─── _kill_process_group_safe ────────────────────────────────────────────────
# Send SIGTERM to the entire process group PGID, wait up to GRACE seconds,
# then SIGKILL survivors.  Idempotent — calling on a dead/unknown PGID is safe.
# Avoids PID 0 and 1 (would kill the entire session or init).
#
# Usage: _kill_process_group_safe PGID [GRACE_SECONDS]
_kill_process_group_safe() {
    local pgid="${1:-}" grace="${2:-10}"
    [[ -z "$pgid" ]] && return 0
    [[ "$pgid" -le 1 ]] && return 0
    kill -- -"$pgid" 2>/dev/null || true
    local i=0
    while kill -0 -- -"$pgid" 2>/dev/null && [[ $i -lt $grace ]]; do
        sleep 1
        i=$(( i + 1 ))
    done
    kill -9 -- -"$pgid" 2>/dev/null || true
}

# ─── _get_pgid ───────────────────────────────────────────────────────────────
# Print the process-group ID of PID, or return 1 if unavailable.
#
# Usage: pgid=$(_get_pgid PID)
_get_pgid() {
    local pid="${1:-}"
    [[ -z "$pid" ]] && return 1
    ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' '
}

# ─── _parent_alive ───────────────────────────────────────────────────────────
# Return 0 (true) if the given PID is still alive, 1 otherwise.
# Fail-open: if PID is unknown or ≤1 (init), returns 0 to avoid false exits.
# Used as a while-loop guard in long-running background subshells so they
# self-terminate when their owner dies (handles SIGKILL, partial-cleanup exits,
# and clean exits equally — no reliance on signal delivery).
#
# Usage: while _parent_alive "$parent_pid"; do ... done
_parent_alive() {
    local p="${1:-}"
    [[ -z "$p" || "$p" -le 1 ]] && return 0
    kill -0 "$p" 2>/dev/null
}
