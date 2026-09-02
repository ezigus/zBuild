#!/usr/bin/env bash
# plugins/tool/orch-sequential/plugin.sh
# Synchronous in-process orchestrator backend (issue #219, ADR-011).
#
# Provides: orchestrator-backend / sequential
# This backend executes each work unit synchronously with no background jobs.
# Pool state is stored under
# ${ZBUILD_POOL_ROOT:-<issue-or-goal-area>/runs/<run_id>/pool}/zbuild-pool-<pool_id>/results/ (ADR-059 §1)
# (#898 per-run isolation).
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_ORCH_SEQUENTIAL_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_SEQUENTIAL_LOADED=1

# ─── _orch_seq_validate_pool_id ──────────────────────────────────────────────
# Rejects pool IDs containing path separators, "..", or whitespace.
# Returns 0 if valid, 1 if invalid (emits a warning to stderr).
_orch_seq_validate_pool_id() {
    local pool_id="$1"
    local caller="${2:-orch_sequential}"
    if [[ "$pool_id" == ".." ]] || grep -qE '(/|\.\.|[[:space:]])' <<< "$pool_id"; then
        warn "${caller}: invalid pool_id (contains /, .., or whitespace): ${pool_id}" || true
        return 1
    fi
    return 0
}

# ─── _orch_seq_pool_dir (#898) ───────────────────────────────────────────────
# Per-run-namespaced pool dir; identical contract to the bash-parallel backend's
# _orch_par_pool_dir. ZBUILD_POOL_ROOT overrides. ZBUILD_RUN_ID is exported by
# the runner.
_orch_seq_pool_dir() {
    # ADR-059 §1: pool dirs live at runs/<run_id>/pool/ under the issue's (or
    # goal's) area. ZBUILD_STATE_DIR already resolves to runs/<run_id>/, so the
    # pool sits inside something a reclaimer can name. The pre-#2004 default was
    # ${TMPDIR}-rooted, which is outside every reclaimable path by construction.
    # ZBUILD_POOL_ROOT still overrides. A caller with no state dir at all
    # resolves under the data root too — nothing here roots in ${TMPDIR}.
    local _root="${ZBUILD_POOL_ROOT:-}"
    if [[ -z "$_root" ]]; then
        if [[ -n "${ZBUILD_STATE_DIR:-}" ]]; then
            _root="${ZBUILD_STATE_DIR%/}/pool"
        else
            # No state dir means no run — an ad-hoc or test caller. It still
            # goes under the DATA ROOT, not ${TMPDIR}: ADR-059 §1 makes the path
            # the keying, so a ${TMPDIR} fallback would be unreclaimable by
            # construction and would reintroduce the very leak #2004 fixed.
            # Same precedence the event bus uses for its unpinned default.
            _root="${ZBUILD_DATA_ROOT:-${ZBUILD_STATE_ROOT:-$HOME/.zbuild}}/runs/${ZBUILD_RUN_ID:-default}/pool"
        fi
    fi
    printf '%s' "${_root}/zbuild-pool-${1}"
}

# ─── orch_spawn ──────────────────────────────────────────────────────────────
# Contract: orch_spawn <pool_id> [count] [role_arg]
# Creates the pool results directory.  count and role_arg are accepted for
# contract compliance but unused by the sequential backend.
orch_spawn() {
    local pool_id="$1"
    _orch_seq_validate_pool_id "$pool_id" "orch_spawn" || return 1
    mkdir -p "$(_orch_seq_pool_dir "$pool_id")/results"
    return 0
}

# ─── orch_dispatch ───────────────────────────────────────────────────────────
# Contract: orch_dispatch <pool_id> <work_unit>
# work_unit: path to an executable script created by orch_make_work_unit, or
#            a bash body string passed to `bash -c` (mock-compatible mode).
# Executes synchronously — no & background.
# Prints slot_id to stdout.  Returns 0 always (errors captured in .exit file).
orch_dispatch() {
    local pool_id="$1"
    local work_unit="$2"
    _orch_seq_validate_pool_id "$pool_id" "orch_dispatch" || return 1
    local pool_dir; pool_dir="$(_orch_seq_pool_dir "$pool_id")"
    local slot_id
    slot_id="$(date +%s%N)-$$-${RANDOM}"
    local result_base="${pool_dir}/results/${slot_id}"

    # Execute synchronously — no background (&)
    local task_rc=0
    if [[ -f "$work_unit" && -x "$work_unit" ]]; then
        # work_unit is a script file path
        bash "$work_unit" > "${result_base}.stdout" 2> "${result_base}.stderr" || task_rc=$?
    else
        # work_unit is a bash body string (mock-compatible mode)
        bash -c "$work_unit" > "${result_base}.stdout" 2> "${result_base}.stderr" || task_rc=$?
    fi
    echo "$task_rc" > "${result_base}.exit"
    echo "$slot_id"
}

# ─── orch_collect ────────────────────────────────────────────────────────────
# Contract: orch_collect <pool_id> [--timeout S]
# Iterates all result files; prints stdout; returns first non-zero rc.
# --timeout is accepted for contract compatibility but ignored (synchronous).
orch_collect() {
    # Exit code convention: 0=all pass, 1=all fail, 2=partial (some pass some fail).
    local pool_id="$1"
    # Accept --timeout flag without error; value is discarded.
    _orch_seq_validate_pool_id "$pool_id" "orch_collect" || return 1

    local pool_dir; pool_dir="$(_orch_seq_pool_dir "$pool_id")"
    local pass_count=0 fail_count=0

    if [[ ! -d "${pool_dir}/results" ]]; then
        return 0
    fi

    for exit_file in "${pool_dir}/results/"*.exit; do
        [[ -f "$exit_file" ]] || continue
        local base="${exit_file%.exit}"
        local rc
        rc="$(cat "$exit_file")"
        [[ -f "${base}.stdout" ]] && cat "${base}.stdout"
        [[ -f "${base}.stderr" ]] && cat "${base}.stderr" >&2
        if [[ $rc -eq 0 ]]; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    if [[ "$fail_count" -eq 0 ]]; then
        rm -rf "$pool_dir"
        return 0
    elif [[ "$pass_count" -gt 0 ]]; then
        return 2  # partial
    else
        return 1  # all failed
    fi
}

# ─── orch_shutdown ───────────────────────────────────────────────────────────
# Contract: orch_shutdown <pool_id>
# Removes the pool directory.  Idempotent — safe to call on non-existent pool.
orch_shutdown() {
    local pool_id="$1"
    _orch_seq_validate_pool_id "$pool_id" "orch_shutdown" || return 1
    rm -rf "$(_orch_seq_pool_dir "$pool_id")"
    return 0
}

# ─── orch_capabilities ───────────────────────────────────────────────────────
# Contract: orch_capabilities → JSON with backend name and capabilities list.
orch_capabilities() {
    printf '{"backend":"sequential","capabilities":["sequential","fanout_sequential"]}\n'
}
