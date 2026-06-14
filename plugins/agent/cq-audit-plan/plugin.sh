#!/usr/bin/env bash
# plugins/agent/cq-audit-plan — CQ audit plan selection (ADR-013, issue #755)
#
# Reads quality-scores.jsonl history and selects which audit lenses run at
# what intensity for the cq-cycle stage.
# legacy-citation: pipeline_select_audits at
#   legacy/scripts/lib/pipeline-intelligence.sh:429-508

[[ -n "${_ZBUILD_CQ_AUDIT_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_CQ_AUDIT_PLAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_AUDIT_PLAN_DIR="$_ZBUILD_PLUGIN_DIR"
_CQ_AUDIT_PLAN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_CQ_AUDIT_PLAN_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_AUDIT_PLAN_ROOT/core/event-bus/event-bus.sh"

cq_audit_plan_run() {
    # shellcheck disable=SC2034  # hook-signature positional; unused in this stage
    local _stage_id="$1"
    local state_file="$2"
    if [[ -z "$state_file" ]]; then
        error "cq_audit_plan_run: requires <stage_id> <state_file>"
        return 2
    fi
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifact_dir="$state_dir/artifacts"

    local audit_plan_file="$artifact_dir/audit-plan.json"

    eb_emit_event "cq.audit_plan.start" "stage=cq-audit-plan"

    # Determine audit intensity from quality-scores history
    local intensity="${ZBUILD_CQ_DEFAULT_INTENSITY:-standard}"
    local scores_file="$state_dir/quality-scores.jsonl"
    if [[ -f "$scores_file" ]]; then
        local avg_score
        avg_score="$(awk -F'"' 'BEGIN{s=0;n=0} /score/{s+=$(NF-1);n++} END{if(n>0) printf "%.2f", s/n}' \
            "$scores_file" 2>/dev/null || true)"
        if [[ -n "$avg_score" ]]; then
            # Upgrade to full intensity when avg score is low (< 0.6)
            if (( $(printf '%s < 0.6\n' "$avg_score" | bc -l 2>/dev/null || echo 0) )); then
                intensity="full"
            fi
        fi
    fi

    # Emit the audit plan
    printf '{"intensity":"%s","lenses":["security","logic","performance","architecture","correctness","edge-case","pessimist"]}\n' \
        "$intensity" | atomic_write "$audit_plan_file"

    eb_emit_event "cq.audit_plan.complete" "stage=cq-audit-plan" "intensity=$intensity"
    return 0
}
