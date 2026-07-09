#!/usr/bin/env bash
# core/pipeline/strategies/map.sh — data-driven map over any declared list dimension (issue #1285)
# ADR-047: generalizes fanout (platforms) to arbitrary declared dimensions.
# When dimension=platforms, behavior is byte-identical to _strategy_run_fanout.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_MAP_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_MAP_LOADED=1

_ZBUILD_STRATEGIES_DIR_MAP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ZBUILD_STRATEGIES_DIR_MAP}/common.sh"

# ─── _strategy_map_resolve_dimension ─────────────────────────────────────────
# Resolves the iteration list for the given dimension name.
# For "platforms": uses _DETECTED_PLATFORMS (set by runner before dispatch).
# For other names: uses _MAP_DIM_<name> array if set; otherwise empty.
# Prints one element per line; no output = empty dimension.
_strategy_map_resolve_dimension() {
    local dim="${1:-platforms}"
    if [[ "$dim" == "platforms" ]]; then
        local p
        for p in "${_DETECTED_PLATFORMS[@]+"${_DETECTED_PLATFORMS[@]}"}"; do
            [[ -n "$p" ]] && printf '%s\n' "$p"
        done
        return 0
    fi
    # Arbitrary dimension: caller must export _MAP_DIM_<name> as an array.
    # Validate dimension name to prevent variable-name injection.
    if [[ ! "$dim" =~ ^[a-zA-Z0-9_]{1,64}$ ]]; then
        warn "map: invalid dimension name: ${dim}" || true
        return 2
    fi
    local arr_name="_MAP_DIM_${dim}"
    # Read the caller's array variable by name — bash 3.2-safe indirect expansion.
    # The array lives in the caller's scope (same sourced shell).
    # shellcheck disable=SC2086
    local -a _dim_arr=()
    eval "_dim_arr=(\"\${${arr_name}[@]}\")" 2>/dev/null || true
    local elem
    for elem in "${_dim_arr[@]+"${_dim_arr[@]}"}"; do
        [[ -n "$elem" ]] && printf '%s\n' "$elem"
    done
}

# ─── _strategy_run_map ───────────────────────────────────────────────────────
# Usage: _strategy_run_map <pool_id> <stage> <roles_out> <state_file> <plugins_root> [dimension]
#   pool_id    — caller-supplied, already validated (no orch_spawn called here)
#   stage      — stage name (e.g. "intake")
#   roles_out  — newline-delimited list of role names
#   state_file — path to pipeline state file
#   plugins_root — path to plugins directory
#   dimension  — list name to iterate (default: "platforms")
#
# Dispatches one work unit per role×element pair in parallel via orch_dispatch.
# When dimension=platforms, behavior is byte-identical to _strategy_run_fanout.
#
# Returns:
#   0 — all succeeded
#   1 — all failed
#   2 — partial (at least one success, at least one fail)
#   3 — empty dimension (no elements to iterate; caller treats as no-op)
#   4 — no plugin found for any role
_strategy_run_map() {
    local pool_id="$1" stage="$2" roles_out="$3" state_file="$4" plugins_root="$5"
    local dimension="${6:-platforms}"
    local success_count=0 fail_count=0 any_plugin_found=false dispatch_count=0
    local -a work_units=() dispatched_plugins=()
    local state_dir; state_dir="$(dirname "$state_file")"

    # Resolve the iteration list for this dimension.
    local -a elements=()
    local _elem
    while IFS= read -r _elem; do
        [[ -n "$_elem" ]] && elements+=("$_elem")
    done < <(_strategy_map_resolve_dimension "$dimension" 2>/dev/null || true)

    if [[ ${#elements[@]} -eq 0 ]]; then
        orch_shutdown "$pool_id" 2>/dev/null || true
        return 3
    fi

    local role element plugin_dir wu
    while IFS= read -r role; do
        [[ -z "$role" ]] && continue
        for element in "${elements[@]}"; do
            # Mirror fanout.sh platform-specific then generic resolution.
            plugin_dir="$(resolve_plugin_for_role "$role" "$element" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && \
                plugin_dir="$(resolve_plugin_for_role "$role" "" "$plugins_root" 2>/dev/null || true)"
            [[ -z "$plugin_dir" ]] && continue
            any_plugin_found=true

            wu="$(_strategy_make_work_unit "$plugin_dir" "$stage" "$state_file" "$element")" || {
                warn "map: failed to create work unit for role=$role element=$element" || true
                fail_count=$((fail_count + 1))
                continue
            }
            work_units+=("$wu")

            orch_dispatch "$pool_id" "$wu" >/dev/null || {
                warn "map: orch_dispatch failed for role=$role element=$element" || true
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

    if [[ "$dispatch_count" -gt 0 ]]; then
        local collect_rc=0
        orch_collect "$pool_id" --timeout "${ZBUILD_ORCH_TIMEOUT:-300}" || collect_rc=$?

        if [[ $collect_rc -eq 0 ]]; then
            success_count=$((success_count + 1))
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
