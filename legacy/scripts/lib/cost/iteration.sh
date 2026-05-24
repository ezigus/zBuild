#!/usr/bin/env bash
# lib/cost/iteration.sh — per-iteration cost recording for the build loop
# Canonical location. lib/loop-cost.sh is a backward-compat shim.
# Sourced by sw-loop.sh. Extracted here for testability (no sw-loop.sh side effects).
[[ -n "${_LOOP_COST_LOADED:-}" ]] && return 0
_LOOP_COST_LOADED=1

# record_iteration_cost <iter_num>
# Appends one JSON line to $ITER_COST_JSONL using deltas from snapshot vars
# (_ITER_SNAP_INPUT, _ITER_SNAP_OUTPUT, _ITER_SNAP_COST_MC) that must be set
# immediately before run_claude_iteration.
record_iteration_cost() {
    local iter_num="${1:-0}"
    [[ -z "${ITER_COST_JSONL:-}" ]] && return 0
    # Snapshot vars must be set by the caller right before run_claude_iteration.
    # Treat "totally unset" (not just empty) as a programming error so the call site
    # gets fixed instead of silently recording cumulative-as-delta.
    if [[ -z "${_ITER_SNAP_INPUT+x}" || -z "${_ITER_SNAP_OUTPUT+x}" || -z "${_ITER_SNAP_COST_MC+x}" ]]; then
        echo "warn: record_iteration_cost: _ITER_SNAP_* not set; skipping iter=${iter_num}" >&2
        return 0
    fi
    local _delta_in=$(( ${LOOP_INPUT_TOKENS:-0}    - ${_ITER_SNAP_INPUT}    ))
    local _delta_out=$(( ${LOOP_OUTPUT_TOKENS:-0}   - ${_ITER_SNAP_OUTPUT}   ))
    local _delta_mc=$((  ${LOOP_COST_MILLICENTS:-0} - ${_ITER_SNAP_COST_MC}  ))
    local _cost_usd="0"
    [[ "$_delta_mc" -gt 0 ]] && \
        _cost_usd=$(awk -v mc="$_delta_mc" 'BEGIN {printf "%.6f", mc/100000}' 2>/dev/null || echo "0")
    local _ts _ts_epoch
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    _ts_epoch=$(date +%s)
    jq -cn \
        --argjson iter "$iter_num" \
        --argjson input "$_delta_in" \
        --argjson output "$_delta_out" \
        --arg cost "$_cost_usd" \
        --arg ts "$_ts" \
        --argjson ts_epoch "$_ts_epoch" \
        --arg issue "${ISSUE_NUMBER:-}" \
        '{iteration: $iter, input_tokens: $input, output_tokens: $output, cost_usd: ($cost|tonumber), ts: $ts, ts_epoch: $ts_epoch, issue: $issue}' \
        2>/dev/null >> "$ITER_COST_JSONL" || true
    # Emit event for parity with cost_record (allows event stream consumers to track iteration cost)
    if type emit_event >/dev/null 2>&1; then
        emit_event "cost.iteration_recorded" \
            "iter=${iter_num}" \
            "input=${_delta_in}" \
            "output=${_delta_out}" \
            "cost_usd=${_cost_usd}" \
            "issue=${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi
}
