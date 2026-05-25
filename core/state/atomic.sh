#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  zBuild core/state/atomic — atomic write + flock + .bak rotation          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# All state writes go through these primitives. See ADR-006.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STATE_ATOMIC_LOADED:-}" ]] && return 0
_ZBUILD_STATE_ATOMIC_LOADED=1

_ZBUILD_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT="$(cd "$_ZBUILD_STATE_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_ZBUILD_ROOT/scripts/lib/helpers.sh"

# ─── locked_state_update ────────────────────────────────────────────────────
# Acquire flock, apply an update function to a state file, atomic-write the result.
#
# Usage:
#   locked_state_update <state_file> <update_function_name>
#
# The update function receives the current state on stdin (or empty if no file)
# and must write the new state to stdout.
locked_state_update() {
    local state_file="$1"
    local update_fn="$2"

    if ! command -v "$update_fn" >/dev/null 2>&1 && ! declare -F "$update_fn" >/dev/null 2>&1; then
        error "locked_state_update: update function not found: $update_fn"
        return 2
    fi

    local lock_file="${state_file}.lock"
    local lock_dir; lock_dir="$(dirname "$lock_file")"
    [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir"
    : > "$lock_file"

    local current; current="$(mktemp)"
    local next; next="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$current' '$next'" RETURN

    if zbuild_has_flock; then
        (
            flock -w 30 9 || { error "locked_state_update: failed to acquire lock on $lock_file"; exit 1; }
            if [[ -f "$state_file" ]]; then
                cp "$state_file" "$current"
                # Validate before passing to update fn
                if ! validate_json "$current" >/dev/null 2>&1; then
                    warn "locked_state_update: $state_file failed validation; using .bak if available"
                fi
            fi
            "$update_fn" < "$current" > "$next"
            atomic_write "$state_file" < "$next"
        ) 9>"$lock_file"
    else
        # Fallback for systems without flock (macOS without brew flock).
        warn "locked_state_update: flock unavailable; using best-effort (race risk)"
        if [[ -f "$state_file" ]]; then
            cp "$state_file" "$current"
        fi
        "$update_fn" < "$current" > "$next"
        atomic_write "$state_file" < "$next"
    fi
}

# ─── read_state ─────────────────────────────────────────────────────────────
# Read a state file; if corrupt, attempt .bak recovery.
read_state() {
    local state_file="$1"
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi
    if validate_json "$state_file" >/dev/null 2>&1; then
        cat "$state_file"
        return 0
    fi
    # Corruption — try .bak
    if [[ -f "${state_file}.bak" ]] && validate_json "${state_file}.bak" >/dev/null 2>&1; then
        warn "read_state: recovered $state_file from .bak"
        cp "${state_file}.bak" "$state_file"
        cat "$state_file"
        return 0
    fi
    error "read_state: $state_file and .bak both corrupt"
    return 2
}
