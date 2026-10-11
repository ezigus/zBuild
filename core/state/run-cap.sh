#!/usr/bin/env bash
# core/state/run-cap.sh — host-wide concurrent run cap (issue #1932, ADR-059 §7).
#
# Off by default. Set ZBUILD_MAX_CONCURRENT_RUNS=N to enable. Fail-open: any
# infrastructure error (unreadable slot dir) admits the run with a warning rather
# than refusing. ZBUILD_NO_RUN_CAP=1 bypasses entirely.
# A slot is live while its process is: a crashed run never writes a final status,
# and a starting run has not written in_progress yet, so the state file cannot
# answer this.

[[ -n "${_ZBUILD_RUN_CAP_LOADED:-}" ]] && return 0
_ZBUILD_RUN_CAP_LOADED=1

# ─── zbuild_run_cap_slot_dir ──────────────────────────────────────────────────
zbuild_run_cap_slot_dir() {
    printf '%s/run-slots\n' "${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}"
}

# ─── zbuild_run_cap_reap_stale ────────────────────────────────────────────────
# Remove slots whose process is gone. Fail-open.
zbuild_run_cap_reap_stale() {
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    [[ -d "$slot_dir" ]] || return 0
    local f pid
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        pid="$(jq -r '.pid // ""' "$f" 2>/dev/null || true)"
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$f" 2>/dev/null || true
        fi
    done < <(find "$slot_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    return 0
}

# ─── zbuild_run_cap_write_slot <run_id> [state_file] ─────────────────────────
# Write <slot_dir>/$$.json. Fail-open (no-op on write error).
zbuild_run_cap_write_slot() {
    local run_id="${1:-}" state_file="${2:-}"
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    mkdir -p "$slot_dir" 2>/dev/null || return 0
    jq -cn --arg run_id "$run_id" --argjson pid "$$" --arg state_file "$state_file" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{run_id:$run_id, pid:$pid, state_file:$state_file, acquired_at:$at}' \
        > "$slot_dir/$$.json" 2>/dev/null || true
}

# ─── zbuild_run_cap_release ───────────────────────────────────────────────────
# Remove this run's slot file. No-op if the slot was never written.
zbuild_run_cap_release() {
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    local slot_file="$slot_dir/$$.json"
    if [[ -f "$slot_file" ]]; then rm -f "$slot_file" 2>/dev/null || true; fi
    return 0
}

# ─── zbuild_run_cap_admit <run_id> [state_file] ──────────────────────────────
# Admission gate. Returns 0 to admit, 1 to refuse (sets _ZBUILD_RUN_CAP_BLOCKERS).
# No-op (returns 0, writes nothing) when ZBUILD_MAX_CONCURRENT_RUNS is unset.
zbuild_run_cap_admit() {
    local run_id="${1:-}" state_file="${2:-}"
    _ZBUILD_RUN_CAP_BLOCKERS=""

    # SPEC-1: off by default
    [[ -n "${ZBUILD_MAX_CONCURRENT_RUNS:-}" ]] || return 0

    # SPEC-4: operator bypass
    if [[ "${ZBUILD_NO_RUN_CAP:-0}" == "1" ]]; then
        printf 'zBuild: ZBUILD_NO_RUN_CAP=1 — run cap bypassed for %s\n' "$run_id" >&2
        return 0
    fi

    local cap="${ZBUILD_MAX_CONCURRENT_RUNS}"
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"

    # SPEC-5: mkdir fail-open
    mkdir -p "$slot_dir" 2>/dev/null || {
        printf 'zBuild: run-cap: cannot create slot dir %s — admitting (fail-open)\n' \
            "$slot_dir" >&2
        return 0
    }

    # SPEC-3: reap stale slots before counting
    zbuild_run_cap_reap_stale 2>/dev/null || true

    # Count live slots and collect blocker run_ids (inline — avoids subshell/global loss).
    # Uses _slot_run_id to avoid shadowing the $run_id admission-request parameter.
    local live_count=0 _loop_f _loop_fname _slot_run_id _blocker_list=""
    while IFS= read -r _loop_f; do
        [[ -f "$_loop_f" ]] || continue
        _loop_fname="$(basename "$_loop_f")"
        # Exclude own potential slot (not yet written, but guard for re-entry)
        [[ "$_loop_fname" == "$$.json" ]] && continue
        _slot_run_id="$(jq -r '.run_id // ""' "$_loop_f" 2>/dev/null || true)"
        live_count=$(( live_count + 1 ))
        _blocker_list="${_blocker_list:+$_blocker_list }${_slot_run_id}"
    done < <(find "$slot_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)

    # SPEC-2: refuse if at or above cap
    if (( live_count >= cap )); then
        _ZBUILD_RUN_CAP_BLOCKERS="$_blocker_list"
        printf 'zBuild: run-cap: refused %s — cap=%d, live=%d, blockers: %s\n' \
            "$run_id" "$cap" "$live_count" "$_ZBUILD_RUN_CAP_BLOCKERS" >&2
        return 1
    fi

    # SPEC-6: below cap — write slot and admit
    zbuild_run_cap_write_slot "$run_id" "$state_file"
    return 0
}
