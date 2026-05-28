#!/usr/bin/env bash
# plugins/tool/orch-ruflo-hive/plugin.sh
# Orchestrator backend — ruflo hive-mind (issue #221, ADR-011).
# Provides: orchestrator-backend / ruflo-hive
#
# Hybrid model: ruflo hive-mind for coordination/notification; local bash
# subshells execute work units. All dispatch/collect/poll/shutdown logic
# lives in core/orch/local_engine.sh (extracted in #281 — shared with
# orch-bash-parallel). This plugin keeps only the backend-specific bits:
# pool-dir naming, pool_id validation, ruflo hive-mind hooks (best-effort
# — their failures do not abort local execution), and capabilities.
#
# Pool layout: ${TMPDIR:-/tmp}/zbuild-hive-<pool_id>/{results,slots}/
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail.

[[ -n "${_ZBUILD_ORCH_RUFLO_HIVE_LOADED:-}" ]] && return 0
_ZBUILD_ORCH_RUFLO_HIVE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_ORCH_HIVE_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_ORCH_HIVE_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/orch/local_engine.sh
source "$_ZBUILD_ORCH_HIVE_ROOT/core/orch/local_engine.sh"

# ─── _orch_hive_pool_dir ─────────────────────────────────────────────────────
_orch_hive_pool_dir() {
    printf '%s' "${TMPDIR:-/tmp}/zbuild-hive-${1}"
}

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

    local pool_dir; pool_dir="$(_orch_hive_pool_dir "$pool_id")"
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
# Contract: orch_dispatch <pool_id> <work_unit>  — local dispatch first (so
# we only notify ruflo for work that actually ran), then best-effort ruflo
# task notification, then print the slot_id. Restores the pre-extraction
# "zbuild:<slot_id>:<work_unit>" description format now that slot_id is
# available before the notification.
orch_dispatch() {
    local pool_id="$1" work_unit="$2"
    _orch_hive_validate_pool_id "$pool_id" "orch_dispatch" || return 1

    # Dispatch locally first (so we only notify ruflo for work that ran).
    # Read slot_id from the engine's _ORCH_LOCAL_LAST_SLOT_ID global rather
    # than command substitution — `$(...)` forks a subshell whose EXIT trap
    # would pkill the wrapper we just spawned (caught in #282 second round).
    _orch_local_dispatch_workunit "$(_orch_hive_pool_dir "$pool_id")" "slots" "$work_unit" "orch_ruflo_hive" \
        >/dev/null || return $?
    local slot_id="$_ORCH_LOCAL_LAST_SLOT_ID"

    # Best-effort ruflo notification — failures do not affect local execution.
    ruflo hive-mind task \
        --description "zbuild:${slot_id}:${work_unit}" \
        >/dev/null 2>&1 || true

    echo "$slot_id"
    return 0
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
    _orch_hive_validate_pool_id "$pool_id" "orch_collect" || return 1
    _orch_local_collect_results "$(_orch_hive_pool_dir "$pool_id")" "slots" "$timeout_s"
}

# ─── orch_shutdown ───────────────────────────────────────────────────────────
# Contract: orch_shutdown <pool_id>  — local shutdown, then best-effort
# ruflo hive-mind shutdown notification.
orch_shutdown() {
    local pool_id="$1"
    _orch_hive_validate_pool_id "$pool_id" "orch_shutdown" || return 1
    _orch_local_shutdown_pool "$(_orch_hive_pool_dir "$pool_id")" "slots"
    ruflo hive-mind shutdown >/dev/null 2>&1 || true
    return 0
}

# ─── orch_capabilities ───────────────────────────────────────────────────────
orch_capabilities() {
    printf '{"backend":"ruflo-hive","capabilities":["parallel","hive_mind","distributed"]}\n'
}
