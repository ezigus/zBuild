#!/usr/bin/env bash
# core/pipeline/strategies/sequential.sh — serialized per-platform dispatch (issue #200/#222)
# ADR-009: platforms run one at a time; always halts on the first collect failure.
# Depends on core/orch/contract.sh being sourced first by the caller (runner.sh).
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_SEQUENTIAL_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_SEQUENTIAL_LOADED=1

_ZBUILD_STRATEGIES_DIR_SEQ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ZBUILD_STRATEGIES_DIR_SEQ}/common.sh"

# ─── _strategy_run_sequential ────────────────────────────────────────────────
# Usage: _strategy_run_sequential <pool_id> <stage> <roles_out> <state_file> <plugins_root>
#   pool_id    — caller-supplied, already validated
#   stage      — stage name
#   roles_out  — newline-delimited list of role names
#   state_file — path to pipeline state file
#   plugins_root — path to plugins directory
#
# Dispatches one work unit at a time via orch_dispatch + orch_collect.
# Halts on first failure (does not continue to next platform/role).
# Always calls orch_shutdown on exit (success or failure).
# Artifact enforcement happens per work unit inside plugin_hook_call (#1906).
#
# Returns:
#   0 — all succeeded
#   1 — any collect/dispatch failure
#   4 — no plugin found for any role (caller may fall back to stage-id lookup)
_strategy_run_sequential() {
    local pool_id="$1" stage="$2" roles_out="$3" state_file="$4" plugins_root="$5"
    local any_plugin_found=false

    local role platform plugin_dir wu prc
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        for platform in "${_DETECTED_PLATFORMS[@]}"; do
            plugin_dir="$(resolve_plugin_for_role "$role" "$platform" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && \
                plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && continue
            any_plugin_found=true

            wu="$(_strategy_make_work_unit "$plugin_dir" "$stage" "$state_file" "$platform")" || {
                warn "sequential: failed to create work unit for role=$role platform=$platform" || true
                orch_shutdown "$pool_id" 2>/dev/null || true
                return 1
            }

            orch_dispatch "$pool_id" "$wu" >/dev/null || {
                warn "sequential: orch_dispatch failed for role=$role platform=$platform" || true
                rm -f "$wu" 2>/dev/null || true
                orch_shutdown "$pool_id" 2>/dev/null || true
                return 1
            }

            prc=0
            orch_collect "$pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}" || prc=$?
            rm -f "$wu" 2>/dev/null || true

            if [[ $prc -ne 0 ]]; then
                warn "sequential: stage=$stage role=$role platform=$platform failed (rc=$prc)" || true
                orch_shutdown "$pool_id" 2>/dev/null || true
                return 1
            fi

        done
    done <<< "$roles_out"

    orch_shutdown "$pool_id" 2>/dev/null || true
    $any_plugin_found || return 4
    return 0
}
