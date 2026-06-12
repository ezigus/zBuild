#!/usr/bin/env bash
# plugins/agent/cq-backtrack — CQ backtrack router (ADR-013, issue #755)
# Classifies findings by category; routes architecture findings to design.
# Non-blocking: degrades to continue-with-warning on exhaustion.
# legacy-citation: pipeline-intelligence.sh:1343/1745 (backtrack-to-stage,
# compound_rebuild_with_feedback)

[[ -n "${_ZBUILD_CQ_BACKTRACK_LOADED:-}" ]] && return 0
_ZBUILD_CQ_BACKTRACK_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_BACKTRACK_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_BACKTRACK_ROOT/core/event-bus/event-bus.sh"

_CQ_MAX_BACKTRACKS="${ZBUILD_CQ_MAX_BACKTRACKS:-2}"

cq_backtrack_init() { return 0; }

cq_backtrack_run() {
    local _state_file="$2"
    local _state_dir; _state_dir="$(dirname "$_state_file")"
    local _art_dir="$_state_dir/artifacts"
    mkdir -p "$_art_dir"

    # Read cycle results
    local _cycle_file="$_art_dir/cq-cycle.json"
    local _cycle_verdict="converged"
    local _findings_count=0
    if [[ -f "$_cycle_file" ]]; then
        _cycle_verdict="$(jq -r '.verdict // "converged"' "$_cycle_file" 2>/dev/null || echo "converged")"
        _findings_count="$(jq -r '.findings | length // 0' "$_cycle_file" 2>/dev/null || echo "0")"
    fi

    # Default: continue (no backtrack needed)
    local _verdict="continue"
    local _target_stage="review"

    # Classify findings by category
    # legacy-citation: pipeline-intelligence.sh:1745-1800 (compound_rebuild_with_feedback)
    # Architecture-class findings route back to design stage
    # legacy-citation: pipeline-intelligence.sh:1343-1400 (pipeline_backtrack_to_stage)
    local _arch_findings=0
    if [[ -f "$_cycle_file" ]]; then
        _arch_findings="$(jq -r '[.findings[]? | select(.finding? | test("architecture";"i"))] | length' \
            "$_cycle_file" 2>/dev/null || echo "0")"
    fi

    # Check backtrack limit to prevent infinite loops
    local _backtrack_count=0
    local _bt_state="$_state_dir/cq-backtrack-count.txt"
    if [[ -f "$_bt_state" ]]; then
        _backtrack_count="$(cat "$_bt_state" 2>/dev/null | tr -d '[:space:]' || echo "0")"
        [[ "$_backtrack_count" =~ ^[0-9]+$ ]] || _backtrack_count=0
    fi

    if [[ "$_arch_findings" =~ ^[0-9]+$ ]] && (( _arch_findings > 0 )) \
       && (( _backtrack_count < _CQ_MAX_BACKTRACKS )); then
        _verdict="backtrack"
        _target_stage="design"
        echo $(( _backtrack_count + 1 )) > "$_bt_state"

        eb_emit_event "recovery.suggestion" \
            "target_stage=${_target_stage}" \
            "reason=architecture_findings" \
            "findings=${_arch_findings}" 2>/dev/null || true
    fi

    printf '{"verdict":"%s","target_stage":"%s","cycle_verdict":"%s","architecture_findings":%s}\n' \
        "$_verdict" "$_target_stage" "$_cycle_verdict" "${_arch_findings:-0}" \
        | atomic_write "$_art_dir/cq-backtrack.json"

    eb_emit_event "plugin.run.complete" \
        "plugin=cq-backtrack" "verdict=${_verdict}" \
        "target_stage=${_target_stage}" 2>/dev/null || true

    return 0
}

cq_backtrack_finalize() { return 0; }
cq_backtrack_cleanup() { return 0; }
