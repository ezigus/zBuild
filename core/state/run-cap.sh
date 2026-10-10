#!/usr/bin/env bash
# core/state/run-cap.sh — host-wide concurrent run cap (issue #1932, ADR-059 §7).
#
# Off by default. Set ZBUILD_MAX_CONCURRENT_RUNS=N to enable. Fail-open: any
# infrastructure error (unreadable slot dir, missing reap function) admits the run
# with a warning rather than refusing. ZBUILD_NO_RUN_CAP=1 bypasses entirely.
# Dead holders are reaped before counting using zbuild_run_is_live (ADR-006).

[[ -n "${_ZBUILD_RUN_CAP_LOADED:-}" ]] && return 0
_ZBUILD_RUN_CAP_LOADED=1

_ZBUILD_RUN_CAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resume.sh
source "$_ZBUILD_RUN_CAP_DIR/resume.sh"

# ─── zbuild_run_cap_slot_dir ──────────────────────────────────────────────────
zbuild_run_cap_slot_dir() {
    printf '%s/run-slots\n' "${ZBUILD_STATE_ROOT:-$HOME/.zbuild/state}"
}

# ─── zbuild_run_cap_reap_stale ────────────────────────────────────────────────
# Scan slot dir; remove slots whose state_file fails zbuild_run_is_live. Fail-open.
zbuild_run_cap_reap_stale() {
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    [[ -d "$slot_dir" ]] || return 0
    local f state_file
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        state_file="$(jq -r '.state_file // ""' "$f" 2>/dev/null || true)"
        if [[ -z "$state_file" ]] || ! zbuild_run_is_live "$state_file" 2>/dev/null; then
            rm -f "$f" 2>/dev/null || true
        fi
    done < <(find "$slot_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    return 0
}

# ─── zbuild_run_cap_count_live [exclude_pid] ─────────────────────────────────
# Echo the count of live slot files (excluding exclude_pid's slot) to stdout.
# Sets _ZBUILD_RUN_CAP_BLOCKER_LIST to a space-separated list of run_ids.
# Fail-open: errors produce count=0 and no blockers.
zbuild_run_cap_count_live() {
    local exclude_pid="${1:-$$}"
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    _ZBUILD_RUN_CAP_BLOCKER_LIST=""
    local count=0 f fname run_id
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        fname="$(basename "$f")"
        [[ "$fname" == "${exclude_pid}.json" ]] && continue
        run_id="$(jq -r '.run_id // ""' "$f" 2>/dev/null || true)"
        count=$(( count + 1 ))
        _ZBUILD_RUN_CAP_BLOCKER_LIST="${_ZBUILD_RUN_CAP_BLOCKER_LIST:+$_ZBUILD_RUN_CAP_BLOCKER_LIST }${run_id}"
    done < <(find "$slot_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
    printf '%d\n' "$count"
}

# ─── zbuild_run_cap_write_slot <run_id> [state_file] ─────────────────────────
# Write <slot_dir>/$$.json. Fail-open (no-op on write error).
zbuild_run_cap_write_slot() {
    local run_id="${1:-}" state_file="${2:-}"
    local slot_dir; slot_dir="$(zbuild_run_cap_slot_dir)"
    mkdir -p "$slot_dir" 2>/dev/null || return 0
    printf '{"run_id":"%s","pid":%d,"state_file":"%s","acquired_at":"%s"}\n' \
        "$run_id" "$$" "${state_file}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
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
