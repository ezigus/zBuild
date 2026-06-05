#!/usr/bin/env bash
# scripts/lib/abort-propagation.sh — ADR-025 abort-propagation contract (Wave 15-B, #684)
#
# Two helpers form the framework's abort-propagation contract. Every
# dispatcher (runner, cycle orchestrator, future strategy plugins) calls
# both at the same two points in every dispatch loop:
#
#   loop {
#       _zbuild_check_abort || return $?         # pre-flight (sentinel)
#       dispatch_child
#       _zbuild_propagate_abort $? || return $?  # post-flight (rc)
#   }
#
# Layer 1 — rc=130 chokepoint via _zbuild_propagate_abort. The helper
# returns the abort rc it was given (NOT a hard-coded 130) so the SIGTERM
# widening in Wave 15-F (#686) becomes a one-line change to the classifier
# (add 143) with no signature break for callers.
#
# Layer 2 — sentinel file ${ZBUILD_STATE_DIR}/.abort.signal via
# _zbuild_check_abort. Cross-subshell signal channel that survives
# `_zbuild_make_fresh_shell` env scrubs (ADR-024) — env vars do not.
#
# Sourced library: no `set -euo pipefail` (would mutate caller options).

[[ -n "${_ZBUILD_ABORT_PROP_LOADED:-}" ]] && return 0
_ZBUILD_ABORT_PROP_LOADED=1

# _zbuild_abort_sentinel_path — resolve sentinel path from ZBUILD_STATE_DIR.
# Empty string if ZBUILD_STATE_DIR is unset (the helpers degrade to no-op
# rather than fabricate a path under cwd).
_zbuild_abort_sentinel_path() {
    if [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
        printf '%s/.abort.signal' "$ZBUILD_STATE_DIR"
    fi
}

# _zbuild_propagate_abort <child_rc>
#   Returns <child_rc> if <child_rc> is an abort rc, else returns 0.
#   Abort rc classes (one-line additions per ADR widening):
#     130 = 128+SIGINT      (Wave 15-B)
#     143 = 128+SIGTERM     (Wave 15-F #686)
#       6 = cycle_abort     (ADR-027 / Wave 17-B #703) — abort_when predicate
#           match inside a cycle; propagates outward through enclosing cycles
#           to the runner, distinct from rc=5 (blocked) and rc=130/143 (signal).
#   Stable signature across widenings — only the classifier changes; all
#   dispatch-site callers benefit automatically.
_zbuild_propagate_abort() {
    local _rc="${1:-0}"
    case "$_rc" in
        130) return 130 ;;
        143) return 143 ;;
        6)   return 6 ;;
        *) return 0 ;;
    esac
}

# _zbuild_check_abort
#   Returns 130 if ${ZBUILD_STATE_DIR}/.abort.signal exists, else 0.
#   Pre-flight sentinel poll for every dispatcher; catches the case where
#   a sibling subshell or parent caught the abort between the previous
#   iteration's post-flight and this iteration's child spawn.
_zbuild_check_abort() {
    local _sentinel
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -z "$_sentinel" ]] && return 0
    [[ -e "$_sentinel" ]] && return 130
    return 0
}

# _zbuild_arm_abort_sentinel
#   Creates the sentinel file. Called by the runner's SIGINT trap as the
#   first action (additive composition onto the existing trap body).
#   Best-effort: a failure to write the sentinel must NOT abort the trap
#   (the rc=130 layer is the in-process fallback).
_zbuild_arm_abort_sentinel() {
    local _sentinel
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -z "$_sentinel" ]] && return 0
    # Parent dir may not exist yet (very early abort); mkdir -p is cheap.
    local _dir
    _dir="$(dirname "$_sentinel")"
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
    : > "$_sentinel" 2>/dev/null || true
    return 0
}

# _zbuild_disarm_abort_sentinel
#   Removes the sentinel file. Called by the runner's EXIT trap after
#   the pipeline.aborted event is emitted, so a subsequent zbuild
#   invocation in the same state dir does not see a stale sentinel.
_zbuild_disarm_abort_sentinel() {
    local _sentinel
    _sentinel="$(_zbuild_abort_sentinel_path)"
    [[ -z "$_sentinel" ]] && return 0
    [[ -e "$_sentinel" ]] && rm -f "$_sentinel" 2>/dev/null || true
    return 0
}
