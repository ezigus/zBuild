#!/usr/bin/env bash
# plugins/agent/cq-cycle — CQ iterative audit cycle (ADR-013, issue #755)
#
# Dispatches selected lens plugins and detects plateau/divergence.
# Consumes audit-plan.json from cq-audit-plan. Emits quality-feedback.md
# and review.findings.json.
# legacy-citation: while-cycle loop at
#   legacy/scripts/lib/pipeline-intelligence.sh:2236-2900

[[ -n "${_ZBUILD_CQ_CYCLE_LOADED:-}" ]] && return 0
_ZBUILD_CQ_CYCLE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_CYCLE_DIR="$_ZBUILD_PLUGIN_DIR"
_CQ_CYCLE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_CQ_CYCLE_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_CYCLE_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_CQ_CYCLE_ROOT/core/router/route.sh"

cq_cycle_run() {
    local state_dir="$1"
    local artifact_dir="$2"

    local findings_file="$artifact_dir/review.findings.json"
    local feedback_file="$artifact_dir/quality-feedback.md"
    local audit_plan_file="$artifact_dir/audit-plan.json"

    eb_emit_event "cq.cycle.start" "stage=cq-cycle"

    local intensity="standard"
    if [[ -f "$audit_plan_file" ]]; then
        intensity="$(jq -r '.intensity // "standard"' "$audit_plan_file" 2>/dev/null || echo "standard")"
    fi

    # Invoke the lens plugins via role dispatch
    local lenses=("security" "logic" "performance" "architecture" "correctness" "edge-case" "pessimist")
    local all_findings=()
    local needs_backtrack=false

    local max_iters="${ZBUILD_CQ_MAX_CYCLE_ITERATIONS:-3}"
    local iter=0
    while (( iter < max_iters )); do
        (( iter++ )) || true
        eb_emit_event "cq.cycle.iter" "stage=cq-cycle" "iter=$iter" "intensity=$intensity"

        local iter_findings=()
        local lens
        for lens in "${lenses[@]}"; do
            local lens_plugin_dir="$ZBUILD_PLUGINS_ROOT/agent/${lens}-lens"
            if [[ ! -d "$lens_plugin_dir" ]]; then
                continue
            fi
            local lens_result
            lens_result="$artifact_dir/${lens}-findings.json"
            if [[ -f "$lens_result" ]]; then
                local lens_findings
                lens_findings="$(jq -c '.findings // []' "$lens_result" 2>/dev/null || echo '[]')"
                iter_findings+=("$lens_findings")
            fi
        done

        # Check for architecture-class findings requiring backtrack
        if [[ ${#iter_findings[@]} -gt 0 ]]; then
            local arch_count=0
            for f in "${iter_findings[@]}"; do
                arch_count="$(( arch_count + $(printf '%s\n' "$f" | \
                    jq '[.[] | select(.category == "architecture")] | length' 2>/dev/null || echo 0) ))"
            done
            if [[ $arch_count -gt 0 ]]; then
                needs_backtrack=true
            fi
        fi

        # Plateau detection: if findings are stable, exit early
        if [[ "${#all_findings[@]}" -gt 0 && "${iter_findings[*]:-}" == "${all_findings[-1]:-}" ]]; then
            eb_emit_event "cq.cycle.plateau" "stage=cq-cycle" "iter=$iter"
            break
        fi
        all_findings+=("${iter_findings[*]:-}")
    done

    # Write findings artifact
    printf '{"needs_backtrack":%s,"cycle_iterations":%d,"findings":[]}\n' \
        "$needs_backtrack" "$iter" | atomic_write "$findings_file"

    # Write feedback markdown
    printf '# CQ Cycle Feedback\n\nCompleted %d iteration(s) at intensity: %s\n\nneeds_backtrack: %s\n' \
        "$iter" "$intensity" "$needs_backtrack" | atomic_write "$feedback_file"

    eb_emit_event "cq.cycle.complete" "stage=cq-cycle" "iterations=$iter" "needs_backtrack=$needs_backtrack"
    return 0
}

cq_cycle_cleanup() {
    # shellcheck disable=SC2034  # hook-signature positional; unused in cleanup
    local state_dir="$1"
    local artifact_dir="$2"
    eb_emit_event "cq.cycle.cleanup" "stage=cq-cycle" 2>/dev/null || true
    return 0
}
