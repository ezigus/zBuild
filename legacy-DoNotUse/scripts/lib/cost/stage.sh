#!/usr/bin/env bash
# lib/cost/stage.sh — per-stage cost recording bracket helpers
# Canonical location. lib/stage-cost.sh is a backward-compat shim.
#
# Usage pattern in each stage function:
#   record_stage_cost_start "stagename"   ← at function entry
#   ...stage work...
#   record_stage_cost_end "stagename"     ← before every return and at natural end
#
# Or use the decorator for automatic pairing:
#   cost_track_stage "stagename" stage_fn_name
#
# Notes:
#   - run_stage_with_retry calls _start/_end once per attempt, so retried stages
#     get N records in stage-costs.jsonl (one per attempt). cost_generate_breakdown
#     groups by stage name and reports `count: N` plus aggregated tokens/cost.
#   - Pipeline resume re-snapshots on the resumed attempt; deltas span only what
#     the resumed attempt consumed, which is the desired semantic.
[[ -n "${_STAGE_COST_LOADED:-}" ]] && return 0
_STAGE_COST_LOADED=1

# record_stage_cost_start <stage_name>
# Call at the top of each stage function. Snapshots current cumulative token totals.
# Bash 3.2 safe: eval is used (not declare -A) because stage names are hardcoded constants.
# Stage name must be a valid bash identifier (letters, digits, underscore; not starting with digit).
record_stage_cost_start() {
    local stage="${1:-}"
    [[ -z "$stage" ]] && return 0
    [[ "$stage" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
    eval "_STAGE_SNAP_INPUT_${stage}=\${TOTAL_INPUT_TOKENS:-0}"
    eval "_STAGE_SNAP_OUTPUT_${stage}=\${TOTAL_OUTPUT_TOKENS:-0}"
    # Prefer CLAUDE_MODEL (set by intelligence routing) over MODEL (--model flag) over default.
    eval "_STAGE_SNAP_MODEL_${stage}=\${CLAUDE_MODEL:-\${MODEL:-sonnet}}"
}

# record_stage_cost_end <stage_name>
# Call before every return in a stage function and at the natural end.
# Computes delta vs snapshot, writes to:
#   1. Global costs.json via cost_record (historical analytics, now with real stage names)
#   2. $ARTIFACTS_DIR/stage-costs.jsonl (pipeline-local, source of truth for cost-breakdown.json)
# No-ops silently when both token deltas are zero (stage made no Claude calls).
record_stage_cost_end() {
    local stage="${1:-}"
    [[ -z "$stage" ]] && return 0
    [[ "$stage" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
    local _vin="_STAGE_SNAP_INPUT_${stage}"
    local _vout="_STAGE_SNAP_OUTPUT_${stage}"
    local _vmodel="_STAGE_SNAP_MODEL_${stage}"
    local _delta_in=$(( ${TOTAL_INPUT_TOKENS:-0}  - ${!_vin:-0} ))
    local _delta_out=$(( ${TOTAL_OUTPUT_TOKENS:-0} - ${!_vout:-0} ))
    # No-op when there were no Claude calls in this stage. eq (not le) so that a
    # negative delta — which signals a counter reset bug — does not get silently
    # swallowed; it falls through to cost_record where the bad data is visible.
    [[ "$_delta_in" -eq 0 && "$_delta_out" -eq 0 ]] && return 0
    # Use snapshotted model so stages that override MODEL locally (e.g. stage_design)
    # are billed at the rate that was in effect when the stage started.
    local _model="${!_vmodel:-${MODEL:-sonnet}}"
    # 1. Global costs.json (historical analytics — real stage names from now on)
    if type cost_record >/dev/null 2>&1; then
        cost_record "$_delta_in" "$_delta_out" "$_model" \
            "$stage" "${ISSUE_NUMBER:-}" 2>/dev/null || true
    fi
    # 2. Pipeline-local sidecar (concurrent-pipeline safe; never queries global ledger).
    # flock-protected so parallel sub-stages (e.g. compound_quality) do not interleave.
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
        local _ts _ts_epoch _cost_usd="0" _sidecar="${ARTIFACTS_DIR}/stage-costs.jsonl"
        _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        _ts_epoch=$(date +%s)
        if type cost_calculate >/dev/null 2>&1; then
            _cost_usd=$(cost_calculate "$_delta_in" "$_delta_out" "$_model" 2>/dev/null || echo "0")
        fi
        local _line
        _line=$(jq -cn \
            --arg stage "$stage" \
            --argjson input "$_delta_in" \
            --argjson output "$_delta_out" \
            --arg model "$_model" \
            --arg cost "$_cost_usd" \
            --arg ts "$_ts" \
            --argjson ts_epoch "$_ts_epoch" \
            --arg issue "${ISSUE_NUMBER:-}" \
            '{stage: $stage, input_tokens: $input, output_tokens: $output, cost_usd: ($cost|tonumber), model: $model, ts: $ts, ts_epoch: $ts_epoch, issue: $issue}' \
            2>/dev/null) || _line=""
        if [[ -n "$_line" ]]; then
            (
                if command -v flock >/dev/null 2>&1; then
                    flock -w 5 200 2>/dev/null || true
                fi
                echo "$_line" >> "$_sidecar" 2>/dev/null || true
            ) 200>"${_sidecar}.lock"
        fi
    fi
}

# cost_track_stage <stage_name> <function_name> [args...]
# Decorator that automatically brackets a stage function with start/end recording.
# Captures and propagates the wrapped function's exit code.
#
# Example:
#   cost_track_stage "build" stage_build
#   cost_track_stage "test"  run_tests --fast
cost_track_stage() {
    local _stage="${1:-}"
    local _fn="${2:-}"
    [[ -z "$_stage" || -z "$_fn" ]] && { echo "usage: cost_track_stage <stage> <fn> [args...]" >&2; return 1; }
    shift 2
    record_stage_cost_start "$_stage"
    local _rc=0
    "$_fn" "$@" || _rc=$?
    record_stage_cost_end "$_stage"
    return $_rc
}
