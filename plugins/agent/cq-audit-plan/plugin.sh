#!/usr/bin/env bash
# plugins/agent/cq-audit-plan — CQ audit plan selection (ADR-013, issue #755)
# Reads quality-scores.jsonl history, branches on avg_score and critical-
# finding count, checks intelligence-cache complexity, writes audit plan.
# legacy-citation: pipeline-intelligence.sh:429-508 (pipeline_select_audits)

[[ -n "${_ZBUILD_CQ_AUDIT_PLAN_LOADED:-}" ]] && return 0
_ZBUILD_CQ_AUDIT_PLAN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_AUDIT_PLAN_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_AUDIT_PLAN_ROOT/core/event-bus/event-bus.sh"

cq_audit_plan_init() { return 0; }

cq_audit_plan_run() {
    local _state_file="$2"
    local _state_dir; _state_dir="$(dirname "$_state_file")"
    local _art_dir="$_state_dir/artifacts"
    mkdir -p "$_art_dir"

    # Read quality-score history to determine avg_score
    # legacy-citation: pipeline-intelligence.sh:453-482
    local _avg_score=75
    local _qs_file="$_state_dir/quality-scores.jsonl"
    if [[ -f "$_qs_file" ]]; then
        local _scores_sum=0 _scores_n=0 _s
        while IFS= read -r _s; do
            local _score; _score="$(printf '%s' "$_s" | jq -r '.score // empty' 2>/dev/null || true)"
            if [[ "$_score" =~ ^[0-9]+$ ]]; then
                _scores_sum=$(( _scores_sum + _score ))
                _scores_n=$(( _scores_n + 1 ))
            fi
        done < "$_qs_file"
        if (( _scores_n > 0 )); then
            _avg_score=$(( _scores_sum / _scores_n ))
        fi
    fi

    # Branch on avg_score: <60 → full, >80 → lightweight, else standard
    # legacy-citation: pipeline-intelligence.sh:470-492
    local _intensity="standard"
    if (( _avg_score < 60 )); then
        _intensity="full"
    elif (( _avg_score > 80 )); then
        _intensity="lightweight"
    fi

    # Check intelligence-cache complexity → upgrade to full
    local _cache_file="$_state_dir/intelligence-cache.json"
    if [[ -f "$_cache_file" ]]; then
        local _complexity; _complexity="$(jq -r '.complexity_level // "normal"' "$_cache_file" 2>/dev/null || echo "normal")"
        if [[ "$_complexity" == "high" || "$_complexity" == "critical" ]]; then
            _intensity="full"
        fi
    fi

    # Determine which lenses run at what depth per intensity
    local _adversarial="true" _architecture="true" _simulation="false" _security="true" _dod="false"
    if [[ "$_intensity" == "lightweight" ]]; then
        _adversarial="false"; _simulation="false"; _dod="false"
    elif [[ "$_intensity" == "full" ]]; then
        _simulation="true"; _dod="true"
    fi

    eb_emit_event "pipeline.audit_selection" \
        "intensity=${_intensity}" "avg_score=${_avg_score}" 2>/dev/null || true

    printf '{"intensity":"%s","avg_score":%d,"lenses":{"adversarial":%s,"architecture":%s,"simulation":%s,"security":%s,"dod":%s}}\n' \
        "$_intensity" "$_avg_score" \
        "$_adversarial" "$_architecture" "$_simulation" "$_security" "$_dod" \
        | atomic_write "$_art_dir/cq-audit-plan.json"

    return 0
}

cq_audit_plan_finalize() { return 0; }
cq_audit_plan_cleanup() { return 0; }
