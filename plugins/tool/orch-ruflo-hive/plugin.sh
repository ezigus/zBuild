#!/usr/bin/env bash
# plugins/tool/orch-ruflo-hive/plugin.sh
# Orchestrator backend — ruflo hive-mind (issue #221, ADR-011).
# Provides: orchestrator-backend / ruflo-hive
#
# Hybrid model: ruflo hive-mind for coordination/notification; local bash
# subshells execute work units (identical to orch-bash-parallel).  ruflo
# hive-mind is used best-effort — its failures do not abort local execution.
#
# Pool layout: ${TMPDIR:-/tmp}/zbuild-hive-<pool_id>/{results,slots}/
#   results/<slot>.{stdout,stderr,exit,inner_pid}
#   slots/<slot>.pid
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail.

[[ -n "${_ZBUILD_ORCH_RUFLO_HIVE_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_RUFLO_HIVE_LOADED=1

# ─── _orch_hive_validate_pool_id ─────────────────────────────────────────────
# Allowlist: ^[a-zA-Z0-9_-]{1,64}$  Returns 0/1; warns on invalid.
_orch_hive_validate_pool_id() {
    local pool_id="$1"
    local caller="${2:-orch_ruflo_hive}"
    if [[ ! "$pool_id" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "${caller}: invalid pool_id: ${pool_id}" || true
        return 1
    fi
    return 0
}

# ─── orch_spawn ──────────────────────────────────────────────────────────────
# Contract: orch_spawn <pool_id> [count] [role_arg]  — creates pool dirs,
# notifies ruflo hive-mind (best-effort).
orch_spawn() {
    local pool_id="$1"
    _orch_hive_validate_pool_id "$pool_id" "orch_spawn" || return 1

    # Check ruflo binary availability here (required for this backend)
    if ! command -v ruflo >/dev/null 2>&1; then
        warn "orch_ruflo_hive: ruflo binary not found in PATH" || true
        return 1
    fi

    local pool_dir="${TMPDIR:-/tmp}/zbuild-hive-${pool_id}"
    mkdir -p "${pool_dir}/results" "${pool_dir}/slots" || {
        warn "orch_ruflo_hive: cannot create pool dir: ${pool_dir}" || true
        return 1
    }

    # Notify ruflo hive-mind (best-effort; failure is non-fatal for local execution)
    ruflo hive-mind init \
        --max-agents "${2:-8}" \
        --persist false \
        >/dev/null 2>&1 || true

    return 0
}

# ─── orch_dispatch ───────────────────────────────────────────────────────────
# Contract: orch_dispatch <pool_id> <work_unit>
# work_unit must be an executable file path (no bash body strings).
# Prints slot_id to stdout.  Returns 0 (dispatch accepted).
orch_dispatch() {
    local pool_id="$1"
    local work_unit="$2"
    _orch_hive_validate_pool_id "$pool_id" "orch_dispatch" || return 1

    if [[ ! -f "$work_unit" || ! -x "$work_unit" ]]; then
        warn "orch_ruflo_hive: work_unit must be a path to an executable file: ${work_unit}" || true
        return 1
    fi

    local pool_dir="${TMPDIR:-/tmp}/zbuild-hive-${pool_id}"

    # Ensure pool dirs exist even if orch_spawn was skipped or failed.
    mkdir -p "${pool_dir}/results" "${pool_dir}/slots" 2>/dev/null || {
        warn "orch_ruflo_hive: pool dir is not writable: ${pool_dir}" || true
        return 1
    }

    local slot_id
    slot_id="$(date +%s%N)-$$-$(openssl rand -hex 8 2>/dev/null || printf '%05d%05d%05d' $RANDOM $RANDOM $RANDOM)"
    local result_base="${pool_dir}/results/${slot_id}"

    # Notify ruflo about this task (best-effort; does not affect local execution)
    ruflo hive-mind task \
        --description "zbuild:${slot_id}:${work_unit}" \
        >/dev/null 2>&1 || true

    # Background subshell: writes inner work-unit PID, traps on exit to propagate
    # signals, then waits for inner and writes .exit file.
    (
        local rc=0 inner=0
        bash "$work_unit" > "${result_base}.stdout" 2> "${result_base}.stderr" &
        inner=$!
        echo "$inner" > "${result_base}.inner_pid"
        # Propagate SIGTERM/EXIT to the actual work-unit process.
        trap 'kill -KILL "$inner" 2>/dev/null || true' EXIT INT TERM
        wait "$inner" || rc=$?
        trap - EXIT INT TERM
        echo "$rc" > "${result_base}.exit"
    ) &
    local worker_pid=$!
    echo "$worker_pid" > "${pool_dir}/slots/${slot_id}.pid"
    echo "$slot_id"
    return 0
}

# ─── _orch_hive_kill_slot ─────────────────────────────────────────────────────
# Sends signal to both the wrapper PID and the inner work-unit PID (if known).
_orch_hive_kill_slot() {
    local sig="$1"
    local wrapper_pid="$2"
    local inner_pid="${3:-}"
    kill "-${sig}" "$wrapper_pid" 2>/dev/null || true
    [[ -n "$inner_pid" ]] && kill "-${sig}" "$inner_pid" 2>/dev/null || true
}

# ─── orch_collect ────────────────────────────────────────────────────────────
# Contract: orch_collect <pool_id> [--timeout S]
# Polls .exit files; streams stdout/stderr; returns first non-zero rc.
# Removes pool dir on clean success.
orch_collect() {
    local pool_id="$1"
    shift
    local timeout_s=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout_s="${2:-0}"; shift 2 ;;
            *) shift ;;
        esac
    done
    _orch_hive_validate_pool_id "$pool_id" "orch_collect" || return 1

    local pool_dir="${TMPDIR:-/tmp}/zbuild-hive-${pool_id}"
    [[ -d "${pool_dir}/slots" ]] || return 0

    # Exit code convention: 0=all pass, 1=all fail, 2=partial (mix of pass+fail).
    # Work-unit exit codes are normalised: 0=pass, non-zero=fail (detail lost).
    local pass_count=0 fail_count=0
    local deadline=0
    [[ "$timeout_s" -gt 0 ]] && deadline=$(( $(date +%s) + timeout_s ))

    local pid_file slot_id result_base wrapper_pid inner_pid rc
    for pid_file in "${pool_dir}/slots/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        result_base="${pool_dir}/results/${slot_id}"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${result_base}.inner_pid" ]] && inner_pid="$(cat "${result_base}.inner_pid")"

        while [[ ! -f "${result_base}.exit" ]]; do
            if [[ "$timeout_s" -gt 0 && "$(date +%s)" -ge "$deadline" ]]; then
                _orch_hive_kill_slot TERM "$wrapper_pid" "$inner_pid"
                sleep 0.5
                _orch_hive_kill_slot KILL "$wrapper_pid" "$inner_pid"
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

# ─── orch_shutdown ────────────────────────────────────────────────────────────
# Contract: orch_shutdown <pool_id>  — SIGTERM → SIGKILL → rm -rf pool dir.
# Kills both the wrapper subshell and the inner work-unit PID for each slot.
# Best-effort notifies ruflo hive-mind of shutdown.
orch_shutdown() {
    local pool_id="$1"
    _orch_hive_validate_pool_id "$pool_id" "orch_shutdown" || return 1

    local pool_dir="${TMPDIR:-/tmp}/zbuild-hive-${pool_id}"
    [[ -d "$pool_dir" ]] || return 0

    local pid_file slot_id wrapper_pid inner_pid
    for pid_file in "${pool_dir}/slots/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${pool_dir}/results/${slot_id}.inner_pid" ]] && \
            inner_pid="$(cat "${pool_dir}/results/${slot_id}.inner_pid")"
        _orch_hive_kill_slot TERM "$wrapper_pid" "$inner_pid"
    done
    sleep 0.5
    for pid_file in "${pool_dir}/slots/"*.pid; do
        [[ -f "$pid_file" ]] || continue
        slot_id="$(basename "${pid_file%.pid}")"
        wrapper_pid="$(cat "$pid_file")"
        inner_pid=""
        [[ -f "${pool_dir}/results/${slot_id}.inner_pid" ]] && \
            inner_pid="$(cat "${pool_dir}/results/${slot_id}.inner_pid")"
        _orch_hive_kill_slot KILL "$wrapper_pid" "$inner_pid"
    done

    # Best-effort ruflo shutdown notification
    ruflo hive-mind shutdown >/dev/null 2>&1 || true

    rm -rf "$pool_dir"
    return 0
}

# ─── orch_capabilities ───────────────────────────────────────────────────────
orch_capabilities() {
    printf '{"backend":"ruflo-hive","capabilities":["parallel","hive_mind","distributed"]}\n'
}
