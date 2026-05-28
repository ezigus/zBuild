#!/usr/bin/env bash
# plugins/tool/orch-bash-parallel/plugin.sh
# Parallel orchestrator backend — background bash jobs (issue #220, ADR-011).
# Provides: orchestrator-backend / bash-parallel
#
# All dispatch/collect/poll/shutdown logic lives in core/orch/local_engine.sh
# (extracted in #281 — shared with orch-ruflo-hive). This plugin keeps only
# the backend-specific bits: pool-dir naming, pool_id validation, and the
# orch_capabilities declaration.
#
# Pool layout: ${TMPDIR:-/tmp}/zbuild-pool-<pool_id>/{results,pids}/
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail.

[[ -n "${_ZBUILD_ORCH_BASH_PARALLEL_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_BASH_PARALLEL_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_ORCH_PAR_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_ORCH_PAR_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/orch/local_engine.sh
source "$_ZBUILD_ORCH_PAR_ROOT/core/orch/local_engine.sh"

# ─── _orch_par_pool_dir ──────────────────────────────────────────────────────
_orch_par_pool_dir() {
    printf '%s' "${TMPDIR:-/tmp}/zbuild-pool-${1}"
}

# ─── _orch_par_validate_pool_id ──────────────────────────────────────────────
# Allowlist: ^[a-zA-Z0-9_-]{1,64}$  Returns 0/1; warns on invalid.
_orch_par_validate_pool_id() {
    local pool_id="$1"
    local caller="${2:-orch_bash_parallel}"
    if [[ ! "$pool_id" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        warn "${caller}: invalid pool_id: ${pool_id}" || true
        return 1
    fi
    return 0
}

# ─── orch_spawn ──────────────────────────────────────────────────────────────
# Contract: orch_spawn <pool_id> [count] [role_arg]  — creates pool dirs.
orch_spawn() {
    local pool_id="$1"
    _orch_par_validate_pool_id "$pool_id" "orch_spawn" || return 1
    local pool_dir; pool_dir="$(_orch_par_pool_dir "$pool_id")"
    mkdir -p "${pool_dir}/results" "${pool_dir}/pids"
    return 0
}

# ─── orch_dispatch ───────────────────────────────────────────────────────────
# Contract: orch_dispatch <pool_id> <work_unit>  — delegates to local_engine.
orch_dispatch() {
    local pool_id="$1" work_unit="$2"
    _orch_par_validate_pool_id "$pool_id" "orch_dispatch" || return 1
    _orch_local_dispatch_workunit "$(_orch_par_pool_dir "$pool_id")" "pids" "$work_unit" "orch_bash_parallel"
}

# ─── orch_collect ────────────────────────────────────────────────────────────
# Contract: orch_collect <pool_id> [--timeout S]  — delegates to local_engine.
# Returns 0/1/2 per the orch contract (single source of truth in local_engine).
orch_collect() {
    local pool_id="$1"; shift
    local timeout_s=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout_s="${2:-0}"; shift 2 ;;
            *) shift ;;
        esac
    done
    _orch_par_validate_pool_id "$pool_id" "orch_collect" || return 1
    _orch_local_collect_results "$(_orch_par_pool_dir "$pool_id")" "pids" "$timeout_s"
}

# ─── orch_shutdown ───────────────────────────────────────────────────────────
# Contract: orch_shutdown <pool_id>  — SIGTERM → SIGKILL → rm -rf pool dir.
orch_shutdown() {
    local pool_id="$1"
    _orch_par_validate_pool_id "$pool_id" "orch_shutdown" || return 1
    _orch_local_shutdown_pool "$(_orch_par_pool_dir "$pool_id")" "pids"
}

# ─── orch_capabilities ───────────────────────────────────────────────────────
orch_capabilities() {
    printf '{"backend":"bash-parallel","capabilities":["parallel","fanout_parallel"]}\n'
}
