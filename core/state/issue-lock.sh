#!/usr/bin/env bash
# core/state/issue-lock.sh — one run per issue, decided at admission (#1688,
# #1764; ADR-059 §4).
#
# WHY THIS EXISTS. Today two runs of one issue are isolated by their per-run
# worktrees, and the worst outcome is #1688's two competing PRs — recoverable by
# hand. ADR-059 §2 re-keys the worktree to the ISSUE, so those two runs would
# share one tree and mutate one `.git/index`. That is silent corruption, and
# #1664 shows the scenario is routine: two runs 18 minutes apart, one local and
# one from the daemon.
#
# So this is a PRECONDITION of the re-keying, not a follow-up. It converts a
# recoverable collision into an explicit refusal, which is the trade ADR-059 §4
# records.
#
# It also closes #1764, which is the same race on a different resource: two
# overlapping snapshots to one issue's state branch, where the loser's commit
# becomes reflog-only. Serialising the runs removes it at the source rather than
# adding a CAS retry to one call site.
#
# NOT A CAPACITY CAP. Legacy shipwright's pipeline lock refuses on a host-wide
# COUNT for an OOM reason, keyed on PID, and admits two runs of one issue
# happily. That is a different control and zBuild still lacks it (#1932).
# Issue exclusivity is a keyed mutex; host capacity is a counted cap.

[[ -n "${_ZBUILD_ISSUE_LOCK_LOADED:-}" ]] && return 0
_ZBUILD_ISSUE_LOCK_LOADED=1

_ZBUILD_ISSUE_LOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resume.sh
source "$_ZBUILD_ISSUE_LOCK_DIR/resume.sh"

# The FD the held lock lives on. A flock lasts exactly as long as an open
# descriptor, so this is what keeps the lock for the run's lifetime — and why
# releasing on exit is the kernel's job, not a trap's. 201 avoids atomic.sh's 9
# and event-bus's own descriptors.
_ZBUILD_ISSUE_LOCK_FD=201
_ZBUILD_ISSUE_LOCK_FILE=""
_ZBUILD_ISSUE_LOCK_HOLDER=""

# ─── zbuild_issue_lock_path <issue_key> ──────────────────────────────────────
# Where the lock for this issue lives. Keyed by the issue (or, for a --goal run,
# whatever identity ADR-059 §5 gives it — #1931), never by run_id: a lock keyed
# by run could never collide and would be pointless.
zbuild_issue_lock_path() {
    local key="${1:-}"
    [[ -n "$key" ]] || return 1
    # Sanitised: the key becomes a filename. Anything outside [A-Za-z0-9._-]
    # collapses to `_` so a goal-derived key can never traverse.
    local safe="${key//[^A-Za-z0-9._-]/_}"
    local root="${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}/locks"
    printf '%s/issue-%s.lock' "$root" "$safe"
}

# ─── zbuild_issue_lock_holder <lock_file> ────────────────────────────────────
# Echo the recorded holder line, for naming a blocker in a refusal message.
zbuild_issue_lock_holder() {
    local f="${1:-}"
    [[ -n "$f" && -f "$f" ]] || return 1
    head -1 "$f" 2>/dev/null
}

# ─── _zbuild_issue_lock_holder_is_live <lock_file> ───────────────────────────
# rc=0 when the recorded holder is PROVABLY still working.
#
# Two independent pieces of evidence, either of which is enough:
#   * its state file says in_progress with a fresh timestamp (zbuild_run_is_live,
#     ADR-006's staleness gate);
#   * its recorded PID is still alive.
#
# The PID check matters because a run that died before writing its first state
# file has no state file to consult — and the state check matters because a PID
# can be reused. Neither alone is sufficient.
_zbuild_issue_lock_holder_is_live() {
    local f="${1:-}" line pid state_file
    line="$(zbuild_issue_lock_holder "$f")" || return 1
    [[ -n "$line" ]] || return 1

    pid="$(printf '%s' "$line" | sed -n 's/.*[[:space:]]pid=\([0-9]*\).*/\1/p')"
    state_file="$(printf '%s' "$line" | sed -n 's/.*[[:space:]]state_file=\([^[:space:]]*\).*/\1/p')"

    if [[ -n "$state_file" && -f "$state_file" ]]; then
        zbuild_run_is_live "$state_file" && return 0
    fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ─── zbuild_issue_lock_acquire <issue_key> <run_id> [state_file] ─────────────
# rc=0 and the lock is HELD for the life of this process.
# rc=1 and _ZBUILD_ISSUE_LOCK_HOLDER names the blocker.
#
# REAP BEFORE ADMISSION, not lazily. A lock whose holder is gone is taken here,
# rather than left to block a live run until someone notices. That shape is the
# one thing worth keeping from legacy shipwright's `reap_stale_pipeline_locks`,
# whose keying is otherwise wrong for this job.
zbuild_issue_lock_acquire() {
    local key="${1:-}" run_id="${2:-}" state_file="${3:-}"
    _ZBUILD_ISSUE_LOCK_HOLDER=""
    [[ -n "$key" ]] || return 0

    # Explicit operator opt-out. Named for what it disables, and deliberately
    # NOT the default: the failure it permits is a corrupted index, which does
    # not announce itself.
    [[ "${ZBUILD_NO_ISSUE_LOCK:-0}" == "1" ]] && return 0

    local lock_file; lock_file="$(zbuild_issue_lock_path "$key")" || return 0
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 0

    if zbuild_has_flock; then
        # A flock is released by the kernel when the holder dies, so a dead
        # holder never blocks anyone — the record below exists only to NAME a
        # live blocker in the refusal.
        eval "exec ${_ZBUILD_ISSUE_LOCK_FD}>>\"\$lock_file\"" 2>/dev/null || return 0
        if ! flock -n "$_ZBUILD_ISSUE_LOCK_FD" 2>/dev/null; then
            _ZBUILD_ISSUE_LOCK_HOLDER="$(zbuild_issue_lock_holder "$lock_file" || printf 'unknown')"
            eval "exec ${_ZBUILD_ISSUE_LOCK_FD}>&-" 2>/dev/null || true
            return 1
        fi
    else
        # No flock (a macOS box without one). Fall back to the record plus
        # liveness — legacy shipwright's shape, and the only thing available.
        # Weaker: two runs starting in the same instant can both see a dead
        # holder. Stated rather than hidden.
        if [[ -f "$lock_file" ]] && _zbuild_issue_lock_holder_is_live "$lock_file"; then
            _ZBUILD_ISSUE_LOCK_HOLDER="$(zbuild_issue_lock_holder "$lock_file" || printf 'unknown')"
            return 1
        fi
    fi

    # Record who holds it, for the next run's refusal message. Truncate first:
    # the FD was opened append-only so the flock survives, so a stale first line
    # would otherwise outlive its run.
    : > "$lock_file" 2>/dev/null || true
    printf 'run_id=%s pid=%s state_file=%s acquired_at=%s\n' \
        "${run_id:-unknown}" "$$" "${state_file:-}" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$lock_file" 2>/dev/null || true
    _ZBUILD_ISSUE_LOCK_FILE="$lock_file"
    return 0
}

# ─── zbuild_issue_lock_release ───────────────────────────────────────────────
# Explicit release. Rarely needed — the kernel drops a flock when the process
# exits — but a long-lived caller (the test harness, a future daemon) should not
# have to exit to let go.
zbuild_issue_lock_release() {
    [[ -n "$_ZBUILD_ISSUE_LOCK_FILE" ]] || return 0
    if zbuild_has_flock; then
        eval "exec ${_ZBUILD_ISSUE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    : > "$_ZBUILD_ISSUE_LOCK_FILE" 2>/dev/null || true
    _ZBUILD_ISSUE_LOCK_FILE=""
    return 0
}
