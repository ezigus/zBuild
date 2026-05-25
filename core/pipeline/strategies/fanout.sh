#!/usr/bin/env bash
# core/pipeline/strategies/fanout.sh — parallel per-platform dispatch (issue #198/#222)
# ADR-009: all platforms run concurrently; stage succeeds iff all succeed (rc=2 = partial).
# Depends on core/orch/contract.sh being sourced first by the caller (runner.sh).
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_FANOUT_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_FANOUT_LOADED=1

_ZBUILD_STRATEGIES_DIR_FANOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ZBUILD_STRATEGIES_DIR_FANOUT}/common.sh"

# ─── _strategy_run_fanout ────────────────────────────────────────────────────
# Usage: _strategy_run_fanout <pool_id> <stage> <roles_out> <state_file> <plugins_root>
#   pool_id    — caller-supplied, already validated (no orch_spawn called here)
#   stage      — stage name (e.g. "intake")
#   roles_out  — newline-delimited list of role names
#   state_file — path to pipeline state file
#   plugins_root — path to plugins directory
#
# Dispatches one work unit per role×platform pair in parallel via orch_dispatch.
# Collects all results with orch_collect.
# Calls orch_shutdown and cleans up work units on both success and failure paths.
#
# Returns:
#   0 — all succeeded
#   1 — all failed or no plugin found for any role (callers treat as stage fail)
#   2 — partial (at least one success, at least one fail)
_strategy_run_fanout() {
    local pool_id="$1" stage="$2" roles_out="$3" state_file="$4" plugins_root="$5"
    local success_count=0 fail_count=0 any_plugin_found=false
    local -a work_units=()

    local role platform plugin_dir wu
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        for platform in "${_DETECTED_PLATFORMS[@]}"; do
            # Intentional fail-open: resolver returns "" when no match — skip silently.
            plugin_dir="$(resolve_plugin_for_role "$role" "$platform" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && \
                plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && continue
            any_plugin_found=true

            wu="$(_strategy_make_work_unit "$plugin_dir" "$stage" "$state_file" "$platform")" || {
                warn "fanout: failed to create work unit for role=$role platform=$platform" || true
                fail_count=$((fail_count + 1))
                continue
            }
            work_units+=("$wu")

            orch_dispatch "$pool_id" "$wu" >/dev/null || {
                warn "fanout: orch_dispatch failed for role=$role platform=$platform" || true
                fail_count=$((fail_count + 1))
                continue
            }
        done
    done <<< "$roles_out"

    if ! $any_plugin_found; then
        _strategy_cleanup_work_units "${work_units[@]+"${work_units[@]}"}"
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 1
    fi

    local collect_rc=0
    orch_collect "$pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}" || collect_rc=$?
    _strategy_cleanup_work_units "${work_units[@]+"${work_units[@]}"}"
    orch_shutdown "$pool_id" 2>/dev/null || true

    # orch_collect exit codes: 0=all pass, 1=all fail, 2=partial (some pass, some fail).
    if [[ $collect_rc -eq 0 ]]; then
        success_count=$((success_count + 1))
    elif [[ $collect_rc -eq 2 ]]; then
        success_count=$((success_count + 1))
        fail_count=$((fail_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi

    if   [[ $fail_count -eq 0 ]];    then return 0
    elif [[ $success_count -gt 0 ]]; then return 2
    else                                  return 1
    fi
}

# ─── _strategy_cleanup_work_units ────────────────────────────────────────────
_strategy_cleanup_work_units() {
    [[ $# -eq 0 ]] && return 0
    rm -f "$@" 2>/dev/null || true
}
