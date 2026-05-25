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
#   1 — all failed (collect failure with no successes)
#   2 — partial (at least one success, at least one fail); callers treat as stage fail
#   4 — no plugin found for any role (caller may fall back to stage-id lookup)
_strategy_run_fanout() {
    local pool_id="$1" stage="$2" roles_out="$3" state_file="$4" plugins_root="$5"
    local success_count=0 fail_count=0 any_plugin_found=false dispatch_count=0
    local -a work_units=() dispatched_plugins=()
    local state_dir; state_dir="$(dirname "$state_file")"

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
            dispatch_count=$((dispatch_count + 1))
            dispatched_plugins+=("$plugin_dir")
        done
    done <<< "$roles_out"

    if ! $any_plugin_found; then
        _strategy_cleanup_work_units "${work_units[@]+"${work_units[@]}"}"
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 4
    fi

    # Only collect if at least one dispatch succeeded; otherwise pool is empty
    # and orch_collect would return 0 (no results) — misreported as success.
    if [[ "$dispatch_count" -gt 0 ]]; then
        local collect_rc=0
        orch_collect "$pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}" || collect_rc=$?

        # orch_collect exit codes: 0=all pass, 1=all fail, 2=partial.
        if [[ $collect_rc -eq 0 ]]; then
            success_count=$((success_count + 1))
            # Validate artifact contracts for all successfully-dispatched plugins.
            # Deduplicate plugin dirs first — same generic plugin may appear for
            # multiple platforms and each unique dir only needs one contract check.
            if declare -F _check_artifact_contract >/dev/null 2>&1; then
                local dp seen_dp
                declare -A seen_dp=()
                for dp in "${dispatched_plugins[@]+"${dispatched_plugins[@]}"}"; do
                    [[ -n "${seen_dp[$dp]:-}" ]] && continue
                    seen_dp[$dp]=1
                    _check_artifact_contract "$dp" "$state_dir" "$stage"
                done
                unset seen_dp
            fi
        elif [[ $collect_rc -eq 2 ]]; then
            success_count=$((success_count + 1))
            fail_count=$((fail_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi

    _strategy_cleanup_work_units "${work_units[@]+"${work_units[@]}"}"
    orch_shutdown "$pool_id" 2>/dev/null || true

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
