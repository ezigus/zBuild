#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/deploy — deploy stage agent (issue #757)                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Stage: deploy (ADR-013 kind:agent amendment, T2, ADR-018 Pattern 1 — one-shot)
# Produces: state/artifacts/deploy-result.json (canonical)
#
# ADR-018 Pattern 1 rationale: deploy is a deterministic side-effect — one
# pr-url.txt input, one release action, done. No iteration loop needed.
# No LLM calls (no route_to_model); kind:agent for guard/orchestration parity
# with the pr-delivery (kind:agent) → pr-open (kind:tool) delegation pattern.
#
# Role: deploy_agent — guard pr-url input + gate verdict; delegate to deploy-release tool.
#
# Lifecycle:
#   deploy_agent_init       — set env vars, emit plugin.init.start
#   deploy_agent_run        — validate state_file, delegate to _deploy_agent_run_inner
#   _deploy_agent_run_inner — read inputs, check gate, delegate to deploy-release tool
#   deploy_agent_finalize   — emit plugin.finalize.complete
#   deploy_agent_cleanup    — no-op
#
# legacy-citation: pipeline-stages-delivery.sh:950 (stage_deploy)

[[ -n "${_ZBUILD_DEPLOY_LOADED:-}" ]] && return 0
_ZBUILD_DEPLOY_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_DEPLOY_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_DEPLOY_ROOT/core/event-bus/event-bus.sh"

# ─── init ────────────────────────────────────────────────────────────────────
deploy_agent_init() {
    export ZBUILD_PLUGIN="deploy"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=deploy"
    return 0
}

# ─── run ─────────────────────────────────────────────────────────────────────
deploy_agent_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "deploy_agent_run: state_file argument required"
        return 2
    fi
    _deploy_agent_run_inner "$state_file"
}

# ADR-018 Pattern 1 (one-shot): guard → dry-run/deploy-release → done.
_deploy_agent_run_inner() {
    local state_file="$1"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"
    local pr_url_in="$artifacts_dir/pr-url.txt"
    local gate_result_in="$artifacts_dir/gate-aggregator-result.json"
    local deploy_result_out="$artifacts_dir/deploy-result.json"

    # Guard: pr-url.txt must exist (required input from pr-delivery stage)
    if [[ ! -f "$pr_url_in" ]]; then
        error "deploy: missing required input pr-url.txt"
        emit_event "deploy.input.missing" "plugin=deploy" "input=pr-url.txt"
        printf '{"schema_version":1,"verdict":"error","reason":"missing pr-url.txt"}\n' \
            > "$deploy_result_out"
        return 2
    fi

    local pr_url; pr_url="$(tr -d '[:space:]' < "$pr_url_in")"

    # Guard: gate-aggregator verdict — skip deploy if gate failed
    if [[ -f "$gate_result_in" ]]; then
        local gate_verdict
        gate_verdict="$(jq -r '.verdict // empty' "$gate_result_in" 2>/dev/null || true)"
        if [[ "$gate_verdict" == "fail" ]]; then
            warn "deploy: gate-aggregator verdict=fail — skipping deploy"
            emit_event "deploy.skipped" "plugin=deploy" "reason=gate_fail"
            printf '{"schema_version":1,"verdict":"skipped","reason":"gate-aggregator verdict=fail","pr_url":"%s"}\n' \
                "$pr_url" > "$deploy_result_out"
            return 0
        fi
    fi

    # Dry-run mode: write sentinel artifact without executing the release side-effect
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        printf '{"schema_version":1,"verdict":"deployed","mode":"dry_run","pr_url":"%s"}\n' \
            "$pr_url" | atomic_write "$deploy_result_out"
        return 0
    fi

    # Delegate to deploy-release tool plugin (executes git-tag + gh release create)
    local release_plugin="$_DEPLOY_ROOT/plugins/tool/deploy-release/plugin.sh"
    if [[ -f "$release_plugin" ]]; then
        # shellcheck source=../../tool/deploy-release/plugin.sh
        source "$release_plugin"
        if type deploy_release_run >/dev/null 2>&1; then
            deploy_release_run "deploy" "$state_file" || {
                local _rc=$?
                emit_event "deploy.tool.failed" "plugin=deploy" "rc=$_rc"
                printf '{"schema_version":1,"verdict":"error","reason":"deploy-release failed","rc":%d}\n' \
                    "$_rc" > "$deploy_result_out"
                return "$_rc"
            }
            return 0
        fi
    fi

    error "deploy: deploy-release plugin not found at: $release_plugin"
    printf '{"schema_version":1,"verdict":"error","reason":"deploy-release plugin missing"}\n' \
        > "$deploy_result_out"
    return 2
}

# ─── finalize ────────────────────────────────────────────────────────────────
deploy_agent_finalize() {
    emit_event "plugin.finalize.complete" "plugin=deploy"
    return 0
}

# ─── cleanup ─────────────────────────────────────────────────────────────────
deploy_agent_cleanup() {
    return 0
}
