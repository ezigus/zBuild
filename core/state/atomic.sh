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

    # _zbuild_lsu_validate_and_copy <state_file> <dest_tmp>
    # Validates state_file (recovering from .bak when needed), then copies the
    # now-valid file into dest_tmp.  Returns 0 on success, 2 if both are corrupt.
    # Stderr diagnostics from validate_json are intentionally NOT suppressed so
    # callers see corruption warnings in their log output.
    _zbuild_lsu_validate_and_copy() {
        local sf="$1" dest="$2"
        [[ -f "$sf" ]] || return 0  # No file yet — fresh start; leave dest empty.
        # A zero-byte file is not valid state; treat it as corrupt so .bak recovery runs.
        # (jq empty considers an empty file valid, so we gate before calling validate_json.)
        if [[ ! -s "$sf" ]]; then
            warn "locked_state_update: $sf is empty; attempting .bak recovery"
            if [[ -f "${sf}.bak" ]] && jq empty "${sf}.bak" >/dev/null 2>&1; then
                # Atomic restore (#946) — a concurrent read_state must never see a
                # torn $sf. A failed restore fails closed rather than silently
                # passing an empty/torn file to the update function.
                atomic_replace "${sf}.bak" "$sf" \
                    || { error "locked_state_update: atomic_replace failed restoring $sf from .bak; failing closed"; return 2; }
            else
                emit_event "state.corruption.unrecoverable" \
                    "state_file=$sf" "reason=empty_and_no_valid_bak" 2>/dev/null || true
                error "locked_state_update: $sf is empty and .bak is missing or corrupt; failing closed"
                return 2
            fi
        fi
        local rc=0
        validate_json "$sf" >/dev/null || rc=$?
        if (( rc == 2 )); then
            # Both sf and .bak are corrupt — emit event (best-effort) then fail closed.
            emit_event "state.corruption.unrecoverable" \
                "state_file=$sf" "reason=both_corrupt" 2>/dev/null || true
            error "locked_state_update: $sf and .bak both corrupt; failing closed"
            return 2
        fi
        # validate_json may have restored .bak into sf; copy whatever is now in
        # sf (guaranteed valid) into the temp working file.
        cp "$sf" "$dest"
    }

    if zbuild_has_flock; then
        (
            flock -w 30 9 || { error "locked_state_update: failed to acquire lock on $lock_file"; exit 1; }
            _zbuild_lsu_validate_and_copy "$state_file" "$current" || exit 2
            "$update_fn" < "$current" > "$next"
            atomic_write "$state_file" < "$next"
        ) 9>"$lock_file"
    else
        # Fallback for systems without flock (macOS without brew flock).
        warn "locked_state_update: flock unavailable; using best-effort (race risk)"
        _zbuild_lsu_validate_and_copy "$state_file" "$current" || return 2
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
    # read_state holds no flock — a concurrent atomic_write may be rotating
    # ${state_file}.bak right now, so the restore must be atomic (#946). A failed
    # restore must not report success on a still-corrupt file.
    if [[ -f "${state_file}.bak" ]] && validate_json "${state_file}.bak" >/dev/null 2>&1; then
        if atomic_replace "${state_file}.bak" "$state_file"; then
            warn "read_state: recovered $state_file from .bak"  # log only on actual success
            cat "$state_file"
            return 0
        fi
        # .bak is valid but the restore failed — fail closed with the accurate cause.
        error "read_state: ${state_file}.bak is valid but restore failed (atomic_replace); failing closed"
        return 2
    fi
    error "read_state: $state_file and .bak both corrupt"
    return 2
}
