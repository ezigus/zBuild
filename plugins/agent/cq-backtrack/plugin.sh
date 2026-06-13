#!/usr/bin/env bash
# plugins/agent/cq-backtrack — CQ backtrack recovery (ADR-013, issue #755)
#
# Reads classified-findings.json needs_backtrack flag from cq-cycle. On
# architecture-class findings, emits recovery.suggestion targeting design.
# Non-blocking: backtrack exhaustion degrades to continue-with-warning.
# legacy-citation: pipeline_backtrack_to_stage at
#   legacy/scripts/lib/pipeline-intelligence.sh:1339-1422

[[ -n "${_ZBUILD_CQ_BACKTRACK_LOADED:-}" ]] && return 0
_ZBUILD_CQ_BACKTRACK_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_BACKTRACK_DIR="$_ZBUILD_PLUGIN_DIR"
_CQ_BACKTRACK_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_CQ_BACKTRACK_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_BACKTRACK_ROOT/core/event-bus/event-bus.sh"

cq_backtrack_run() {
    local state_dir="$1"
    local artifact_dir="$2"

    local result_file="$artifact_dir/cq-backtrack-result.json"
    local findings_file="$artifact_dir/review.findings.json"

    eb_emit_event "cq.backtrack.start" "stage=cq-backtrack"

    local needs_backtrack=false
    local action="continue"
    if [[ -f "$findings_file" ]]; then
        needs_backtrack="$(jq -r '.needs_backtrack // false' "$findings_file" 2>/dev/null || echo false)"
    fi

    local max_attempts="${ZBUILD_CQ_MAX_BACKTRACK_ATTEMPTS:-2}"
    local attempt_count=0
    local count_file="$state_dir/cq-backtrack-count"
    if [[ -f "$count_file" ]]; then
        attempt_count="$(cat "$count_file" 2>/dev/null || echo 0)"
    fi

    if [[ "$needs_backtrack" == "true" ]]; then
        if (( attempt_count < max_attempts )); then
            (( attempt_count++ )) || true
            printf '%d\n' "$attempt_count" > "$count_file"
            action="backtrack"
            eb_emit_event "recovery.suggestion" "stage=cq-backtrack" \
                "target_stage=design" "reason=architecture_findings" \
                "attempt=$attempt_count"
        else
            # Exhausted backtrack budget — degrade to continue-with-warning
            action="continue_with_warning"
            eb_emit_event "cq.backtrack.exhausted" "stage=cq-backtrack" \
                "max_attempts=$max_attempts"
        fi
    fi

    printf '{"action":"%s","needs_backtrack":%s,"attempt_count":%d}\n' \
        "$action" "$needs_backtrack" "$attempt_count" | atomic_write "$result_file"

    eb_emit_event "cq.backtrack.complete" "stage=cq-backtrack" "action=$action"
    # Always exit 0 — cq-backtrack is non-blocking per ADR-013
    return 0
}
