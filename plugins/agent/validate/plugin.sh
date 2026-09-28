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
# _validate_write_result <dir> <verdict> <disposition> <reason> [data_json]
# Plugin-specific detail rides under `data` (ADR-054 v2).
_validate_write_result() {
    local artifact_dir="$1" verdict="$2" disposition="$3" reason="$4" data="${5:-}"
    [[ -n "$data" ]] || data='{}'
    jq -n \
        --arg v "$verdict" \
        --arg d "$disposition" \
        --arg r "$reason" \
        --argjson data "$data" \
        '{result_contract:2,verdict:$v,disposition:$d,reason:$r,data:$data}' \
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
    local state_file="$1"; : "$state_file"
    # Every path comes from the engine (ADR-055 §1, #1826): the artifact dir it
    # exports at dispatch (ADR-058 §3) and the input index it resolves. None is
    # derived here — without them there is nowhere legitimate to read or write.
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$artifacts_dir" ]]; then
        error "validate: the engine provided no ZBUILD_ARTIFACT_DIR — nowhere to write a result"
        return 1
    fi
    mkdir -p "$artifacts_dir"

    local _si_path="${ZBUILD_STAGE_INPUTS:-}"
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

    # Validate checks the deployment deploy MADE. A deploy that did not deploy
    # (skipped: the gate did not pass; error: the release failed) left nothing
    # to validate — probing a fixed address and calling it healthy asserted
    # something about a deployment that never happened.
    local deploy_verdict
    deploy_verdict="$(jq -r '.verdict // empty' "$deploy_result_in" 2>/dev/null || true)"
    if [[ "$deploy_verdict" != "deployed" ]]; then
        _validate_write_result "$artifacts_dir" "skipped" "complete" \
            "nothing to validate: deploy reported '${deploy_verdict:-no verdict}', not deployed"
        stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "skip" \
            "nothing was deployed (deploy: ${deploy_verdict:-no verdict}), so nothing was validated" \
            "No probe ran."
        return 0
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

    # WHERE to probe: the address deploy reported (data.health_url — e.g. a
    # preview environment or a per-version URL), else the operator's configured
    # ZBUILD_HEALTH_CHECK_URL. An address that is not http(s) is a setup fault.
    local probe_url
    probe_url="$(jq -r '.data.health_url // .health_url // empty' "$deploy_result_in" 2>/dev/null || true)"
    if [[ -n "$probe_url" && ! "$probe_url" =~ ^https?:// ]]; then
        error "validate: deploy reported a non-http(s) address: $probe_url"
        _validate_write_result "$artifacts_dir" "error" "misconfigured" \
            "deploy reported an address that is not http(s): $probe_url"
        stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "error" \
            "deploy reported an address validate cannot probe" \
            "$(printf -- '- reported: %s\n- only http(s) addresses are probed' "$probe_url")"
        return 1
    fi
    [[ -n "$probe_url" ]] || probe_url="${ZBUILD_HEALTH_CHECK_URL:-}"

    # No probe target is a setup the operator must fix, not an unhealthy
    # deployment: say `misconfigured` and do not probe. (health-check itself
    # reads ZBUILD_HEALTH_CHECK_URL; asking before delegating is the only way
    # to tell "not configured" from "configured and failing", since both come
    # back as a non-zero rc.)
    if [[ -z "$probe_url" ]]; then
        error "validate: no probe target — set ZBUILD_HEALTH_CHECK_URL"
        _validate_write_result "$artifacts_dir" "error" "misconfigured" \
            "no probe target configured: ZBUILD_HEALTH_CHECK_URL is not set"
        stage_summary_write "$artifacts_dir/validate-summary.md" "validate" "error" \
            "no probe target is configured, so nothing could be validated" \
            "Set ZBUILD_HEALTH_CHECK_URL to the deployment's health endpoint. No probe ran."
        return 1
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
            hc_out="$(ZBUILD_HEALTH_CHECK_URL="$probe_url" health_check_run "validate" "$state_file" 2>&1)" || hc_rc=$?
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
            # The probe's own rc and output are the diagnosis (curl: 6 DNS,
            # 7 refused, 22 HTTP error, 28 timeout); the stage's rc is clamped
            # to 1 (ADR-054 §4), so they are kept here, under data.
            _validate_write_result "$artifacts_dir" "error" "complete" \
                "health probe failed (rc=$hc_rc)" \
                "$(jq -cn --argjson rc "$hc_rc" --arg out "$hc_snippet" '{probe_rc:$rc, probe_output:$out}')"
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
