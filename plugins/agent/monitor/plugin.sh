#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugins/agent/monitor — Monitor stage agent (issue #758)                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Stage: monitor (ADR-013, T1, non-blocking)
# Produces: state/artifacts/monitor-report.json (primary)
#           state/artifacts/monitor-verdict.json (secondary)
#
# Lifecycle:
#   monitor_stage_init        — set env vars, emit plugin.init.start
#   monitor_stage_run         — derive paths, delegate to _monitor_stage_run_inner
#   _monitor_stage_run_inner  — redact → route_to_model → write artifacts
#   monitor_stage_finalize    — emit plugin.finalize.complete
#   monitor_stage_cleanup     — no-op
#
# ADR-018 Pattern 1 (one-shot): read deploy artifacts → assess → write reports.
# Side-effecting probes deferred to a future kind:tool plugin.
# legacy-citation: pipeline-stages-monitor.sh:150 (stage_monitor)

[[ -n "${_ZBUILD_MONITOR_LOADED:-}" ]] && return 0
_ZBUILD_MONITOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_MONITOR_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_MONITOR_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_MONITOR_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/router/route.sh
source "$_MONITOR_ROOT/core/router/route.sh"

# ─── init ───────────────────────────────────────────────────────────────────
monitor_stage_init() {
    export ZBUILD_PLUGIN="monitor"
    export ZBUILD_PLUGIN_KIND="agent"
    emit_event "plugin.init.start" "plugin=monitor"
    return 0
}

# ─── run ────────────────────────────────────────────────────────────────────
monitor_stage_run() {
    local state_file="${2:-}"
    if [[ -z "$state_file" ]]; then
        error "monitor_stage_run: state_file argument required"
        return 2
    fi
    _monitor_stage_run_inner "$state_file"
}

# ADR-018 Pattern 1 (one-shot): assemble prompt → route_to_model T1 → write artifacts.
_monitor_stage_run_inner() {
    local state_file="$1"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artifacts_dir="$state_dir/artifacts"
    mkdir -p "$artifacts_dir"

    local deploy_result_json="$artifacts_dir/deploy-result.json"
    local pr_url_txt="$artifacts_dir/pr-url.txt"
    local report_out="$artifacts_dir/monitor-report.json"
    local verdict_out="$artifacts_dir/monitor-verdict.json"
    local scope_manifest="$state_dir/scope-manifest.md"

    emit_event "monitor.started" "plugin=monitor"

    # Dry-run mode: write sentinel artifacts without calling route_to_model
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        printf '{"schema_version":1,"verdict":"pass","summary":"dry-run monitor","checks":[]}\n' \
            | atomic_write "$report_out"
        printf '{"verdict":"pass","reason":"dry_run"}\n' \
            | atomic_write "$verdict_out"
        return 0
    fi

    # Build prompt from available artifacts
    local prompt_file; prompt_file="$(mktemp)"
    {
        printf 'You are the monitor agent for zBuild pipeline run %s.\n' \
            "${ZBUILD_RUN_ID:-unknown}"
        printf 'Perform a one-shot health assessment of the deployment and return a JSON report.\n\n'

        if [[ -f "$deploy_result_json" ]]; then
            printf '## Deploy Result\n'
            cat "$deploy_result_json"
            printf '\n\n'
        else
            printf '## Deploy Result\n(not available)\n\n'
        fi

        if [[ -f "$pr_url_txt" ]]; then
            printf '## PR URL\n'
            cat "$pr_url_txt"
            printf '\n\n'
        fi

        printf '## Task\n'
        printf 'Assess deployment health. Return ONLY valid JSON with this exact shape:\n'
        printf '{"schema_version":1,"verdict":"pass","summary":"<one-line assessment>","checks":[]}\n'
        printf 'verdict must be "pass" or "degraded". No prose outside the JSON object.\n'
    } > "$prompt_file"

    # Redact prompt before model call (ADR-004 chokepoint)
    local redacted_file; redacted_file="$(mktemp)"
    apply_scope_redaction "$prompt_file" "$redacted_file" "$scope_manifest" || {
        rm -f "$prompt_file" "$redacted_file"
        return 2
    }
    rm -f "$prompt_file"

    emit_event "monitor.check" "plugin=monitor"

    # One-shot route_to_model call (ADR-018 Pattern 1, T1)
    # Capture rc without set +e/-e to avoid polluting caller's errexit flag.
    local response rc=0
    response="$(route_to_model "T1" "$(cat "$redacted_file")")" || rc=$?
    rm -f "$redacted_file"

    if [[ $rc -ne 0 ]]; then
        emit_event "monitor.alert" "plugin=monitor" "reason=model_error" "rc=$rc"
        printf '{"verdict":"degraded","reason":"model_error","rc":%d}\n' "$rc" \
            | atomic_write "$verdict_out"
        return 1
    fi

    # Extract JSON object from response
    local report_json
    report_json="$(printf '%s' "$response" | grep -o '{.*}' | tail -1 || true)"
    if [[ -z "$report_json" ]]; then
        report_json='{"schema_version":1,"verdict":"degraded","summary":"no structured response from model","checks":[]}'
    fi

    # Determine verdict from report
    local verdict
    verdict="$(printf '%s' "$report_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('verdict','degraded'))" 2>/dev/null || echo 'degraded')"

    printf '%s\n' "$report_json" | atomic_write "$report_out"
    printf '{"verdict":"%s","reason":"model_assessment"}\n' "$verdict" \
        | atomic_write "$verdict_out"

    if [[ "$verdict" != "pass" ]]; then
        emit_event "monitor.alert" "plugin=monitor" "verdict=$verdict"
        return 1
    fi

    return 0
}

# ─── finalize ───────────────────────────────────────────────────────────────
monitor_stage_finalize() {
    emit_event "plugin.finalize.complete" "plugin=monitor"
    return 0
}

# ─── cleanup ────────────────────────────────────────────────────────────────
monitor_stage_cleanup() {
    return 0
}
