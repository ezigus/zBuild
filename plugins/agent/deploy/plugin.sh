#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/deploy — deploy stage agent (issues #757, #1846)             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Stage: deploy (ADR-013 kind:agent amendment, T2, ADR-018 Pattern 1 — one-shot)
# Produces: ZBUILD_ARTIFACT_DIR/deploy-result.json (v2 contract, ADR-054/055/060)
#
# ADR-018 Pattern 1 rationale: deploy is a deterministic side-effect — one
# pr-url input, one release action, done. No iteration loop needed.
# No LLM calls (no route_to_model); kind:agent for guard/orchestration parity
# with the pr-delivery (kind:agent) → pr-open (kind:tool) delegation pattern.
#
# Role: deploy_agent — guard pr-url input + gate verdict; delegate to deploy-release tool.
#
# Lifecycle:
#   deploy_agent_run        — validate env, delegate to _deploy_agent_run_inner
#   _deploy_agent_run_inner — read inputs via ZBUILD_STAGE_INPUTS, check gate,
#                             delegate to deploy-release tool
#
# legacy-citation: pipeline-stages-delivery.sh:950 (stage_deploy)

[[ -n "${_ZBUILD_DEPLOY_LOADED:-}" ]] && return 0
_ZBUILD_DEPLOY_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_DEPLOY_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DEPLOY_ROOT/core/event-bus/event-bus.sh"

# Write a v2 result envelope to ZBUILD_ARTIFACT_DIR/deploy-result.json.
# Args: out_dir verdict disposition reason [data_json]
_deploy_write_result() {
    local out_dir="$1" verdict="$2" disposition="$3" reason="$4"
    local data_json="${5:-}"
    [[ -z "$data_json" ]] && data_json='{}'
    mkdir -p "$out_dir"
    jq -n \
        --arg verdict "$verdict" \
        --arg disposition "$disposition" \
        --arg reason "$reason" \
        --argjson data "$data_json" \
        '{result_contract:2, verdict:$verdict, disposition:$disposition, reason:$reason, data:$data}' \
        | atomic_write "$out_dir/deploy-result.json"
}

# ─── run ─────────────────────────────────────────────────────────────────────
deploy_agent_run() {
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"
    if [[ -z "$artifacts_dir" ]]; then
        error "deploy_agent_run: ZBUILD_ARTIFACT_DIR not set"
        return 1
    fi
    mkdir -p "$artifacts_dir"
    _deploy_agent_run_inner
}

# ADR-018 Pattern 1 (one-shot): guard → dry-run/deploy-release → done.
_deploy_agent_run_inner() {
    local artifacts_dir="${ZBUILD_ARTIFACT_DIR:-}"

    # Resolve inputs via ZBUILD_STAGE_INPUTS (ADR-055 §1)
    local pr_url_in gate_result_in
    pr_url_in="$(jq -r '.inputs.pr_url // empty' "${ZBUILD_STAGE_INPUTS:-/dev/null}" 2>/dev/null || true)"
    gate_result_in="$(jq -r '.inputs.gate_aggregator_result // empty' "${ZBUILD_STAGE_INPUTS:-/dev/null}" 2>/dev/null || true)"

    # Guard: pr_url input must exist (required input from pr-delivery stage)
    if [[ ! -f "$pr_url_in" ]]; then
        error "deploy: missing required input pr_url"
        emit_event "deploy.input.missing" "plugin=deploy" "input=pr_url"
        _deploy_write_result "$artifacts_dir" "error" "broken" "missing pr_url input"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "no pr_url input, so there was nothing to deploy" \
            "The pr-delivery stage produced no PR; no release was attempted."
        return 1
    fi

    local pr_url; pr_url="$(tr -d '[:space:]' < "$pr_url_in")"

    # Dry-run mode: write sentinel artifact without executing the release side-effect.
    # (checked BEFORE the gate guard so isolation/dry-run needs no gate result)
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        local _dry_data
        _dry_data="$(jq -n --arg pr_url "$pr_url" '{pr_url:$pr_url,mode:"dry_run"}')"
        _deploy_write_result "$artifacts_dir" "deployed" "complete" \
            "dry run — no release side-effect was executed" \
            "$_dry_data"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "dry run — no release side-effect was executed" \
            "Nothing was deployed. This verdict asserts nothing about a real deploy."
        return 0
    fi

    # Guard: gate-aggregator verdict — FAIL-CLOSED. The deploy side-effect must not
    # run without a gate decision: a MISSING gate result is refused, not silently
    # skipped (#757 review finding — gate bypass). (When wired in #1328 the gate is a
    # required upstream input; here we enforce its presence at runtime, outside dry-run.)
    if [[ ! -f "$gate_result_in" ]]; then
        error "deploy: gate-aggregator result missing — refusing deploy (fail-closed)"
        emit_event "deploy.gate.missing" "plugin=deploy"
        _deploy_write_result "$artifacts_dir" "error" "broken" \
            "gate-aggregator-result missing"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
            "refused to deploy: no gate-aggregator verdict was present" \
            "Fail-closed. An absent gate decision is not an approval to deploy."
        return 1
    fi

    local gate_verdict
    gate_verdict="$(jq -r '.verdict // empty' "$gate_result_in" 2>/dev/null || true)"

    # Fail-closed ALLOWLIST: proceed ONLY on an explicit pass. Any other verdict —
    # fail, route_<target>, an empty verdict, or a jq parse error (→ empty) — skips
    # the deploy side-effect rather than proceeding (#757 review / Copilot: a
    # skip-only-on-fail denylist would let route_design or a malformed gate proceed).
    if [[ "$gate_verdict" != "pass" ]]; then
        warn "deploy: gate-aggregator verdict='${gate_verdict:-<none>}' is not pass — skipping deploy"
        emit_event "deploy.skipped" "plugin=deploy" "reason=gate_not_pass"
        local _skip_data
        _skip_data="$(jq -n --arg pr_url "$pr_url" '{pr_url:$pr_url}')"
        _deploy_write_result "$artifacts_dir" "skipped" "complete" \
            "gate-aggregator verdict not pass: ${gate_verdict:-<none>}" \
            "$_skip_data"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "skip" \
            "skipped the deploy: the gate verdict was ${gate_verdict:-<none>}, not pass" \
            "Nothing was deployed. Only an explicit pass authorises the release side-effect."
        return 0
    fi

    # Delegate to deploy-release tool plugin (executes git-tag + gh release create)
    if [[ -z "${_ZBUILD_DEPLOY_RELEASE_LOADED:-}" ]]; then
        local release_plugin="$_DEPLOY_ROOT/plugins/tool/deploy-release/plugin.sh"
        if [[ ! -f "$release_plugin" ]]; then
            error "deploy: deploy-release plugin not found at: $release_plugin"
            _deploy_write_result "$artifacts_dir" "error" "broken" \
                "deploy-release plugin missing"
            stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "error" \
                "the deploy-release plugin is missing, so nothing was deployed" \
                "This is an installation fault, not a pipeline one."
            return 1
        fi
        # shellcheck source=../../tool/deploy-release/plugin.sh
        source "$release_plugin"
    fi

    deploy_release_run || {
        local _rc=$?
        emit_event "deploy.tool.failed" "plugin=deploy" "rc=$_rc"
        _deploy_write_result "$artifacts_dir" "error" "unavailable" \
            "deploy-release failed (rc=$_rc)"
        stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "fail" \
            "the release step failed (rc=$_rc)" \
            "The gate authorised a deploy but the release did not complete."
        return 1
    }

    local _success_data
    _success_data="$(jq -n --arg pr_url "$pr_url" '{pr_url:$pr_url}')"
    _deploy_write_result "$artifacts_dir" "deployed" "complete" \
        "deployed ${pr_url}" \
        "$_success_data"
    stage_summary_write "$artifacts_dir/deploy-summary.md" "deploy" "pass" \
        "deployed the change" \
        "$(printf -- '- pr: %s\n- see deploy-release-summary.md for the tag' "$pr_url")"
    return 0
}

# ─── cleanup ─────────────────────────────────────────────────────────────────
