#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/validate — validate stage agent (issue #757)                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Stage: validate (ADR-013 kind:agent amendment, T2, ADR-018 Pattern 1 — one-shot)
# Produces: state/artifacts/validate-result.json (canonical)
#
# ADR-018 Pattern 1 rationale: validate is a single health probe — one read query
# against the deployed service, done. No iteration loop needed.
# No LLM calls (no route_to_model); kind:agent for guard/orchestration parity
# with the pr-delivery (kind:agent) → pr-open (kind:tool) delegation pattern.
#
# Role: validate_agent — read deploy-result input; delegate health probe to health-check tool.
#
# Lifecycle:
#   validate_agent_run        — validate state_file, delegate to _validate_agent_run_inner
#   _validate_agent_run_inner — read deploy-result, delegate to health-check tool
#   validate_agent_cleanup    — no-op
#
# legacy-citation: pipeline-stages-monitor.sh:6 (stage_validate)

[[ -n "${_ZBUILD_VALIDATE_LOADED:-}" ]] && return 0
_ZBUILD_VALIDATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_VALIDATE_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_VALIDATE_ROOT/core/event-bus/event-bus.sh"

# ─── result helper ───────────────────────────────────────────────────────────
_validate_write_result() {
    local artifact_dir="$1" verdict="$2" disposition="$3" reason="$4"
    jq -n \
        --arg v "$verdict" \
        --arg d "$disposition" \
        --arg r "$reason" \
        '{result_contract:2,verdict:$v,disposition:$d,reason:$r,data:{}}' \
        | atomic_write "$artifact_dir/validate-result.json"
}

# ─── run ─────────────────────────────────────────────────────────────────────
validate_agent_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "validate_agent_run: state_file argument required"
        if [[ -n "${ZBUILD_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_ARTIFACT_DIR"
            _validate_write_result "$ZBUILD_ARTIFACT_DIR" "error" "broken" \
                "engine dispatched this stage with no state file"
        fi
        stage_summary_write "${ZBUILD_ARTIFACT_DIR:+$ZBUILD_ARTIFACT_DIR/validate-summary.md}" "validate" "error" \
            "the engine dispatched this stage with no state file, so it could not run" \
            "No work was attempted. This is an engine contract violation, not a fault in the change."
        return 1
    fi
    _validate_agent_run_inner "$state_file"
}

# ADR-018 Pattern 1 (one-shot): guard → dry-run/health-check → done.
_validate_agent_run_inner() {
    local state_file="$1"
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$(dirname "$state_file")/artifacts}"
    mkdir -p "$artifacts_dir"

    # Resolve deploy_result input path from ZBUILD_STAGE_INPUTS (ADR-055).
    # Falls back to a sibling stage-inputs.json when the env var is not set
    # (e.g. when called directly from tests or from the legacy dispatch path).
    local _si_path="${ZBUILD_STAGE_INPUTS:-$(dirname "$state_file")/stage-inputs.json}"
    local deploy_result_in=""
    if [[ -n "$_si_path" && -f "$_si_path" ]]; then
        deploy_result_in="$(jq -r '.inputs.deploy_result // empty' "$_si_path")"
    fi

    # Guard: deploy-result.json must exist (required input from deploy stage)
    if [[ -z "$deploy_result_in" || ! -f "$deploy_result_in" ]]; then
        error "validate: missing required input deploy-result.json"
        emit_event "validate.input.missing" "plugin=validate" "input=deploy-result.json"
        _validate_write_result "$artifacts_dir" "error" "broken" \
            "missing required input: deploy-result.json was not provided or does not exist"
        stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "error" \
            "no deploy-result.json, so nothing could be validated" \
            "The deploy stage produced no result; the health probe never ran."
        return 1
    fi

    # Dry-run mode: write sentinel artifact without executing the health probe
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        _validate_write_result "$artifacts_dir" "healthy" "complete" \
            "dry run — the health probe was not executed"
        stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "skip" \
            "dry run — the health probe was not executed" \
            "No deployment was validated. This verdict asserts nothing about service health."
        return 0
    fi

    # Delegate to health-check tool plugin (performs the actual HTTP/smoke probe)
    local hc_plugin="$_VALIDATE_ROOT/plugins/tool/health-check/plugin.sh"
    if [[ -f "$hc_plugin" ]]; then
        # shellcheck source=../../tool/health-check/plugin.sh
        source "$hc_plugin"
        if type health_check_run >/dev/null 2>&1; then
            # Preserve probe diagnostics and propagate failure — a failed probe must not
            # return success (#757 review). rc clamped to 1 (ADR-054 §4b).
            local hc_out hc_rc=0
            hc_out="$(health_check_run "validate" "$state_file" 2>&1)" || hc_rc=$?
            if [[ $hc_rc -eq 0 ]]; then
                _validate_write_result "$artifacts_dir" "healthy" "complete" \
                    "health probe reported the deployment healthy"
                stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "pass" \
                    "the health probe reported the deployment healthy" \
                    "$(printf -- '- probe: health-check\n- verdict: healthy')"
                return 0
            fi
            local hc_snippet; hc_snippet="${hc_out:0:500}"
            emit_event "validate.probe.failed" "plugin=validate" "rc=$hc_rc"
            _validate_write_result "$artifacts_dir" "error" "complete" \
                "health probe failed (rc=$hc_rc)"
            stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "fail" \
                "the health probe failed (rc=$hc_rc)" \
                "$(printf -- '- probe output: %s' "$hc_snippet")"
            return 1
        fi
    fi

    error "validate: health-check plugin not found at: $hc_plugin"
    _validate_write_result "$artifacts_dir" "error" "broken" \
        "health-check plugin missing — installation fault"
    stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "error" \
        "the health-check plugin is missing, so nothing could be validated" \
        "No probe ran. This is an installation fault, not a deployment one."
    return 1
}

# ─── cleanup ─────────────────────────────────────────────────────────────────
