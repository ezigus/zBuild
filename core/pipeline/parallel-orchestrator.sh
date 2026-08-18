#!/usr/bin/env bash
# core/pipeline/parallel-orchestrator.sh — ADR-039 parallel stage-group executor
# (#1131, EPIC #1129 A2). EXECUTION only — the template parse (`type: parallel`
# → `parallel:<gid>` dispatch unit + `_TPL_PARALLEL_*` vars) already landed in
# #1130. This file consumes those vars and runs a group's members concurrently
# with full per-member isolation, then aggregates in declaration order.
#
# Public surface:
#   parallel_group_run <group_id> <state_dir> <state_file>
#     rc: 0   = all members succeeded, OR on_member_error=continue (member
#               failures are advisory and do not fail the group)
#         1   = one+ member failed AND on_member_error=collect (failures
#               collected → the group fails)
#         4   = config error (no members / no dispatch hook / bad args)
#         130 = aborted (SIGINT/SIGTERM observed mid-run)
#     Sets globals:
#       _PARALLEL_LAST_VERDICTS_BLOB  JSON {"<member>":{"verdict":..,"status":..}}
#       _PARALLEL_LAST_FAILURE_COUNT  int (members with rc!=0)
#
# Member dispatch goes through a runner-registered hook `parallel_dispatch_stage`
# (the sibling of cycle-orchestrator's `cycle_dispatch_stage`), so the
# orchestrator stays plugin-agnostic and unit tests can stub the hook.
#
# Sourced library: do NOT add `set -euo pipefail` here.

[[ -n "${_ZBUILD_PARALLEL_ORCH_LOADED:-}" ]] && return 0
_ZBUILD_PARALLEL_ORCH_LOADED=1

_PARALLEL_ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PARALLEL_ORCH_ROOT="$(cd "$_PARALLEL_ORCH_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$_PARALLEL_ORCH_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../event-bus/event-bus.sh
source "$_PARALLEL_ORCH_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=./template.sh
source "$_PARALLEL_ORCH_ROOT/core/pipeline/template.sh"
# Parent-serial state writes use _update_stage_status / _zbuild_state_set_stage_verdict.
# shellcheck source=./state_helpers.sh
source "$_PARALLEL_ORCH_ROOT/core/pipeline/state_helpers.sh"

# ─── Constants ───────────────────────────────────────────────────────────────
# Hard cap mirrors scripts/run-mutation.sh::_zb_default_jobs — a many-core host
# (or a mis-set max_parallel) must not oversubscribe the bounded pool.
readonly _PARALLEL_MAX_JOBS_CAP=8

# ─── Public globals (set by parallel_group_run) ──────────────────────────────
_PARALLEL_LAST_VERDICTS_BLOB="{}"
_PARALLEL_LAST_FAILURE_COUNT=0

# ─── Trap state ──────────────────────────────────────────────────────────────
# In-flight member subshell pids (FIFO-pool); read by the signal teardown.
_PARALLEL_PIDS=()
_PARALLEL_TRAP_GROUP_ID=""

# ─── _parallel_default_jobs — portable CPU count ─────────────────────────────
# No shared lib exports this (_zb_default_jobs lives inside run-mutation.sh /
# run-tests.sh as a script-local), so clone the same logic: Linux `nproc`,
# macOS `sysctl -n hw.ncpu`, fall back to 4, cap at 8.
_parallel_default_jobs() {
    local n
    n="$( { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; } | head -1 )"  # sigpipe-ok: writer emits exactly one line
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=4
    (( n > _PARALLEL_MAX_JOBS_CAP )) && n=$_PARALLEL_MAX_JOBS_CAP
    printf '%s' "$n"
}

# ─── _parallel_resolve_max <group_safe_id> ───────────────────────────────────
# max = _TPL_PARALLEL_MAX_<gid> (template) || ZBUILD_PARALLEL_JOBS (env override,
# ADR-039) || _parallel_default_jobs. Always clamped to 1.._PARALLEL_MAX_JOBS_CAP.
# max_parallel=1 degrades the group to sequential dispatch (debug escape hatch).
_parallel_resolve_max() {
    local safe="$1"
    local max_var="_TPL_PARALLEL_MAX_${safe}"
    local max="${!max_var:-}"
    if [[ -z "$max" ]]; then
        if [[ "${ZBUILD_PARALLEL_JOBS:-}" =~ ^[1-9][0-9]*$ ]]; then
            max="$ZBUILD_PARALLEL_JOBS"
        else
            max="$(_parallel_default_jobs)"
        fi
    fi
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=1
    (( max > _PARALLEL_MAX_JOBS_CAP )) && max=$_PARALLEL_MAX_JOBS_CAP
    printf '%s' "$max"
}

# ─── _parallel_emit — eb_emit_event wrapper with group envelope ──────────────
_parallel_emit() {
    local type="$1"; shift
    eb_emit_event "$type" "group_id=${_PARALLEL_TRAP_GROUP_ID:-unknown}" "$@" \
        2>/dev/null || true
}

# ─── Trap composition ────────────────────────────────────────────────────────
# Mirror cycle-orchestrator's split: the group owns ONLY INT/TERM; the runner
# owns EXIT. The drain loop waits on every member before returning, so the sole
# orphan risk is a signal mid-wait — covered here. On signal: kill in-flight
# members (incl. their plugin/LLM subprocesses), clear traps, return 130.
_parallel_install_traps() {
    trap '_parallel_on_signal SIGINT' INT
    trap '_parallel_on_signal SIGTERM' TERM
}
_parallel_clear_traps() {
    trap - INT TERM
}
_parallel_kill_inflight() {
    local p
    # TERM pass: children first (pkill -P reaps the member subshell's plugin/LLM
    # subprocess so no orphaned model call survives the abort), then the subshell.
    for p in "${_PARALLEL_PIDS[@]:-}"; do
        [[ -z "$p" ]] && continue
        pkill -TERM -P "$p" 2>/dev/null || true
        kill -TERM "$p" 2>/dev/null || true
    done
    # KILL pass: anything that ignored TERM.
    for p in "${_PARALLEL_PIDS[@]:-}"; do
        [[ -z "$p" ]] && continue
        pkill -KILL -P "$p" 2>/dev/null || true
        kill -KILL "$p" 2>/dev/null || true
    done
}
_parallel_on_signal() {
    local sig="$1"
    _parallel_emit "parallel.group.complete" "status=aborted" "signal=$sig"
    _parallel_kill_inflight
    _parallel_clear_traps
    _PARALLEL_PIDS=()
    return 130
}

# ─── _parallel_run_member <member> <state_dir> <state_file> <slot> ────────────
# Runs in a forked `( ) &` subshell. Sets its OWN stage identity + stage-io seq
# label (ADR-039 §3 isolation), dispatches the member via the
# parallel_dispatch_stage hook, and writes ONLY private per-slot sidecars
# (slot.rc / slot.verdict / slot.status). NEVER touches state_file — the parent
# does all run-state mutation serially after the drain (parent-serial writes
# keep the #887 concurrent-state-corruption class closed by construction).
_parallel_run_member() {
    local member="$1" state_dir="$2" state_file="$3" slot="$4"
    local job_dir="$state_dir/parallel-${_PARALLEL_TRAP_GROUP_ID}"

    # ADR-039 §3: per-member stage identity set INSIDE the subshell, never
    # inherited across members — the structural cure for the route_to_model
    # global-state corruption that forced ADR-038's fan-out to blank this var.
    export ZBUILD_CURRENT_STAGE="$member"
    # Per-member stage-io seq label "<prefix>.<slot>" so concurrent members get
    # independent, non-colliding sequence numbers. Prefix is the group's pipeline
    # cardinal (exported by the runner via ZBUILD_SEQ_PREFIX); fall back to the
    # bare slot when invoked standalone (unit/integration test).
    if [[ -n "${ZBUILD_SEQ_PREFIX:-}" ]]; then
        export ZBUILD_STAGE_IO_SEQ_LABEL="${ZBUILD_SEQ_PREFIX}.${slot}"
    else
        export ZBUILD_STAGE_IO_SEQ_LABEL="$slot"
    fi

    _parallel_emit "parallel.member.dispatch.start" "member=$member" "slot=$slot"

    _PARALLEL_DISPATCH_VERDICT=""
    _PARALLEL_DISPATCH_VERDICT_RAW=""
    _PARALLEL_DISPATCH_STATUS=""
    _PARALLEL_DISPATCH_REASON=""
    # `&& rc=0 || rc=$?` captures rc AND inhibits errexit at the call site.
    local rc=0
    parallel_dispatch_stage "$member" "$state_file" && rc=0 || rc=$?

    local verdict="${_PARALLEL_DISPATCH_VERDICT:-}"
    local status="${_PARALLEL_DISPATCH_STATUS:-}"
    [[ -z "$verdict" ]] && verdict="missing"
    if [[ -z "$status" ]]; then
        if [[ $rc -eq 0 ]]; then status="complete"; else status="failed"; fi
    fi

    # Private per-slot sidecars (run-mutation.sh model). NEVER state_file.
    printf '%s' "$rc"      > "$job_dir/$slot.rc"      2>/dev/null || true
    printf '%s' "$verdict" > "$job_dir/$slot.verdict" 2>/dev/null || true
    printf '%s' "$status"  > "$job_dir/$slot.status"  2>/dev/null || true

    _parallel_emit "parallel.member.dispatch.complete" \
        "member=$member" "slot=$slot" "rc=$rc" "verdict=$verdict" "status=$status"
    return "$rc"
}

# ─── parallel_group_run <group_id> <state_dir> <state_file> ───────────────────
parallel_group_run() {
    local group_id="$1" state_dir="$2" state_file="$3"
    if [[ -z "$group_id" || -z "$state_dir" || -z "$state_file" ]]; then
        error "parallel_group_run: group_id, state_dir, state_file required"
        return 4
    fi
    local safe="${group_id//-/_}"

    _PARALLEL_TRAP_GROUP_ID="$group_id"
    _PARALLEL_LAST_VERDICTS_BLOB="{}"
    _PARALLEL_LAST_FAILURE_COUNT=0

    if ! declare -F parallel_dispatch_stage >/dev/null 2>&1; then
        error "parallel_orchestrator: no parallel_dispatch_stage hook registered (runner wires this)"
        _parallel_emit "parallel.group.complete" "status=error" "reason=no_dispatch_hook"
        return 4
    fi

    local flow_var="_TPL_PARALLEL_FLOW_${safe}"
    local flow_csv="${!flow_var:-}"
    if [[ -z "$flow_csv" ]]; then
        error "parallel group '$group_id': no members declared"
        _parallel_emit "parallel.group.complete" "status=error" "reason=no_members"
        return 4
    fi
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a members=($flow_csv)
    IFS="$IFS_save"

    local on_err_var="_TPL_PARALLEL_ON_ERR_${safe}"
    local on_err="${!on_err_var:-continue}"

    local max; max="$(_parallel_resolve_max "$safe")"

    local job_dir="$state_dir/parallel-${group_id}"
    rm -rf "$job_dir" 2>/dev/null || true
    mkdir -p "$job_dir" 2>/dev/null || true

    # Snapshot the caller's stage identity — members own ZBUILD_CURRENT_STAGE
    # inside their subshells; restore on return so the next dispatch unit is clean.
    local _prior_stage_set=0 _prior_stage=""
    if [[ -n "${ZBUILD_CURRENT_STAGE+x}" ]]; then
        _prior_stage_set=1
        _prior_stage="$ZBUILD_CURRENT_STAGE"
    fi

    _parallel_install_traps
    _parallel_emit "parallel.group.start" \
        "members=${#members[@]}" "max_parallel=$max" "on_member_error=$on_err"

    # ── Bounded-parallel FIFO pool (drain-oldest order). Launch each member in
    #    its own subshell, track its pid; once in-flight == max, wait on the
    #    OLDEST pid and shift the array; drain the tail after the loop.
    #    on_member_error never short-circuits — every member is launched
    #    regardless of sibling failure.
    _PARALLEL_PIDS=()
    local slot=0 m
    for m in "${members[@]}"; do
        [[ -z "$m" ]] && continue
        slot=$(( slot + 1 ))
        ( _parallel_run_member "$m" "$state_dir" "$state_file" "$slot" ) &
        _PARALLEL_PIDS+=("$!")
        if [[ ${#_PARALLEL_PIDS[@]} -ge $max ]]; then
            wait "${_PARALLEL_PIDS[0]}" 2>/dev/null || true
            _PARALLEL_PIDS=("${_PARALLEL_PIDS[@]:1}")
        fi
    done
    local _p
    for _p in "${_PARALLEL_PIDS[@]:-}"; do
        [[ -n "$_p" ]] && wait "$_p" 2>/dev/null || true
    done
    _PARALLEL_PIDS=()

    _parallel_clear_traps

    # Restore caller's stage identity.
    if [[ $_prior_stage_set -eq 1 ]]; then
        export ZBUILD_CURRENT_STAGE="$_prior_stage"
    else
        unset ZBUILD_CURRENT_STAGE
    fi

    # ── Aggregate AFTER join, in member-DECLARATION order (deterministic). The
    #    PARENT performs ALL state writes serially here; members touched no
    #    state_file. A missing sidecar (member crashed) → fail slot, never a
    #    silently-short aggregate (run-mutation.sh `(no result)` posture).
    local blob="{}" fail=0
    slot=0
    for m in "${members[@]}"; do
        [[ -z "$m" ]] && continue
        slot=$(( slot + 1 ))
        local rc verdict status
        rc="$(cat "$job_dir/$slot.rc" 2>/dev/null || echo 1)"
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
        verdict="$(cat "$job_dir/$slot.verdict" 2>/dev/null || echo missing)"
        status="$(cat "$job_dir/$slot.status" 2>/dev/null || echo failed)"
        [[ -z "$verdict" ]] && verdict="missing"
        [[ -z "$status" ]] && status="failed"
        # Parent-serial state writes (ADR-039 §3).
        _update_stage_status "$state_file" "$m" "$status" 2>/dev/null || true
        if declare -F _zbuild_state_set_stage_verdict >/dev/null 2>&1; then
            _zbuild_state_set_stage_verdict "$state_file" "$m" "$verdict" 2>/dev/null || true
        fi
        blob="$(jq -c --arg s "$m" --arg v "$verdict" --arg st "$status" \
            '. + {($s): {verdict:$v, status:$st}}' <<< "$blob" 2>/dev/null)" || blob="{}"
        [[ "$rc" -ne 0 ]] && fail=$(( fail + 1 ))
        # Issue OUT (ADR-039): per-member terminal render — the runner registers
        # this hook so the orchestrator stays render-free. Called in declaration
        # order (this loop is parent-serial), so lines never interleave.
        if declare -F parallel_member_complete_hook >/dev/null 2>&1; then
            parallel_member_complete_hook "$group_id" "$m" "$slot" "$rc" "$verdict" "$status" || true
        fi
    done

    _PARALLEL_LAST_VERDICTS_BLOB="$blob"
    _PARALLEL_LAST_FAILURE_COUNT="$fail"

    # Issue OUT (ADR-039): optional group-completion trailer (mirror cycle exit).
    if declare -F parallel_group_complete_hook >/dev/null 2>&1; then
        parallel_group_complete_hook "$group_id" "${#members[@]}" "$fail" || true
    fi

    local group_status="complete"
    [[ $fail -gt 0 ]] && group_status="failed"
    _parallel_emit "parallel.group.complete" \
        "status=$group_status" "members=${#members[@]}" "failure_count=$fail"

    _PARALLEL_TRAP_GROUP_ID=""

    # on_member_error: both `continue` and `collect` run ALL members; only
    # `collect` propagates a member failure outward (group fails → runner halts).
    if [[ $fail -gt 0 && "$on_err" == "collect" ]]; then
        return 1
    fi
    return 0
}
