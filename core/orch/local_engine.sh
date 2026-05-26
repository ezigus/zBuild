#!/usr/bin/env bash
# core/orch/local_engine.sh — shared dispatch/collect/poll/shutdown for the
# local-execution orchestrator backends (orch-bash-parallel, orch-ruflo-hive).
# Extracted from those two plugins in #281 because they had ~80% duplication
# and the #269 0/1/2 normaliser fix had to be applied twice (and still missed
# orch-mock — caught belatedly in #278). Single source of truth now.
#
# Pool layout (caller chooses prefix + pid subdir name):
#   <pool_dir>/<pid_subdir>/<slot>.pid       — wrapper subshell PID
#   <pool_dir>/results/<slot>.{stdout,stderr,exit,inner_pid}
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail.

[[ -n "${_ZBUILD_ORCH_LOCAL_ENGINE_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_LOCAL_ENGINE_LOADED=1

_ZBUILD_ORCH_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ORCH_LOCAL_ROOT="$(cd "$_ZBUILD_ORCH_LOCAL_DIR/../.." && pwd)"

# Defensive source: warn (scripts/lib/helpers.sh).
if ! declare -F warn >/dev/null 2>&1; then
    source "$_ZBUILD_ORCH_LOCAL_ROOT/scripts/lib/helpers.sh"
fi

# _orch_local_make_slot_id — collision-resistant slot id (epoch-ns + PID + rand)
_orch_local_make_slot_id() {
    date +%s%N
    printf -- '-%s-' "$$"
    openssl rand -hex 8 2>/dev/null || printf '%05d%05d%05d' $RANDOM $RANDOM $RANDOM
}

# _orch_local_kill_slot <sig> <wrapper_pid> [inner_pid]
# Sends signal to both the wrapper PID and the inner work-unit PID (if known).
_orch_local_kill_slot() {
    local sig="$1"
    local wrapper_pid="$2"
    local inner_pid="${3:-}"
    kill "-${sig}" "$wrapper_pid" 2>/dev/null || true
    [[ -n "$inner_pid" ]] && kill "-${sig}" "$inner_pid" 2>/dev/null || true
}

# _orch_local_dispatch_workunit <pool_dir> <pid_subdir> <work_unit> <caller_tag>
# Dispatches <work_unit> (must be an executable file path) in a background
# subshell. Records wrapper PID and inner PID; installs trap to propagate
# SIGTERM/EXIT to the inner process. Prints slot_id to stdout. Returns 0 on
# successful dispatch, 1 on validation/permission failure.
_orch_local_dispatch_workunit() {
    local pool_dir="$1"
    local pid_subdir="$2"
    local work_unit="$3"
    local caller_tag="${4:-orch_local}"

    if [[ ! -f "$work_unit" || ! -x "$work_unit" ]]; then
        warn "${caller_tag}: work_unit must be a path to an executable file: ${work_unit}" || true
        return 1
    fi

    # Ensure pool dirs exist even if the caller skipped pre-spawn.
    mkdir -p "${pool_dir}/results" "${pool_dir}/${pid_subdir}" 2>/dev/null || {
        warn "${caller_tag}: pool dir is not writable: ${pool_dir}" || true
        return 1
    }

    local slot_id
    slot_id="$(_orch_local_make_slot_id | tr -d '\n')"
    local result_base="${pool_dir}/results/${slot_id}"

    # Background subshell: writes inner work-unit PID, traps on exit to
    # propagate signals, then waits for inner and writes .exit file.
    (
        local rc=0 inner=0
        bash "$work_unit" > "${result_base}.stdout" 2> "${result_base}.stderr" &
        inner=$!
        echo "$inner" > "${result_base}.inner_pid"
        trap 'kill -KILL "$inner" 2>/dev/null || true' EXIT INT TERM
        wait "$inner" || rc=$?
        trap - EXIT INT TERM
        echo "$rc" > "${result_base}.exit"
    ) &
    local worker_pid=$!
    echo "$worker_pid" > "${pool_dir}/${pid_subdir}/${slot_id}.pid"
    echo "$slot_id"
    return 0
}

# _orch_local_collect_results <pool_dir> <pid_subdir> <timeout_s>
# Polls .exit files for every slot in <pool_dir>/<pid_subdir>/; streams
# stdout/stderr. Returns the 0/1/2 normalised orch contract code:
#   0 = all dispatched work units exited 0  (pool dir removed)
#   1 = all dispatched work units exited non-zero (pool dir preserved)
#   2 = mixed: at least one pass and at least one fail (pool dir preserved)
# Work-unit exit codes are normalised — original rc is not passed through.
# Single source of truth for the 0/1/2 normaliser (#269 + #278 + #281).
_orch_local_collect_results() {
    local pool_dir="$1"
    local pid_subdir="$2"
    local timeout_s="${3:-0}"

    [[ -d "${pool_dir}/${pid_subdir}" ]] || return 0

    local pass_count=0 fail_count=0
    local deadline=0
    [[ "$timeout_s" -gt 0 ]] && deadline=$(( $(date +%s) + timeout_s ))

    local pid_file slot_id result_base wrapper_pid inner_pid rc
    for pid_file in "${pool_dir}/${pid_subdir}/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        result_base="${pool_dir}/results/${slot_id}"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${result_base}.inner_pid" ]] && inner_pid="$(cat "${result_base}.inner_pid")"

        while [[ ! -f "${result_base}.exit" ]]; do
            if [[ "$timeout_s" -gt 0 && "$(date +%s)" -ge "$deadline" ]]; then
                _orch_local_kill_slot TERM "$wrapper_pid" "$inner_pid"
                sleep 0.5
                _orch_local_kill_slot KILL "$wrapper_pid" "$inner_pid"
                echo "124" > "${result_base}.exit"
                break
            fi
            sleep 0.1
        done

        rc="$(cat "${result_base}.exit" 2>/dev/null || echo 1)"
        [[ -f "${result_base}.stdout" ]] && cat "${result_base}.stdout"
        [[ -f "${result_base}.stderr" ]] && cat "${result_base}.stderr" >&2
        if [[ "$rc" -eq 0 ]]; then
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

# _orch_local_shutdown_pool <pool_dir> <pid_subdir>
# Best-effort SIGTERM → 0.5s → SIGKILL on every slot, then rm -rf the pool dir.
# Idempotent — safe to call on non-existent pools.
_orch_local_shutdown_pool() {
    local pool_dir="$1"
    local pid_subdir="$2"

    [[ -d "$pool_dir" ]] || return 0

    local pid_file slot_id wrapper_pid inner_pid
    for pid_file in "${pool_dir}/${pid_subdir}/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${pool_dir}/results/${slot_id}.inner_pid" ]] && \
            inner_pid="$(cat "${pool_dir}/results/${slot_id}.inner_pid")"
        _orch_local_kill_slot TERM "$wrapper_pid" "$inner_pid"
    done
    sleep 0.5
    for pid_file in "${pool_dir}/${pid_subdir}/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${pool_dir}/results/${slot_id}.inner_pid" ]] && \
            inner_pid="$(cat "${pool_dir}/results/${slot_id}.inner_pid")"
        _orch_local_kill_slot KILL "$wrapper_pid" "$inner_pid"
    done
    rm -rf "$pool_dir"
    return 0
}
