#!/usr/bin/env bash
# plugins/tool/health-check — health-check executor (kind:tool, T0, issue #757)
# Performs HTTP/smoke probe for the validate agent. No LLM calls.
# ZBUILD_DRY_RUN=1 returns mock success response without executing curl.
# Probe URL read from ZBUILD_HEALTH_CHECK_URL env var.

[[ -n "${_ZBUILD_HEALTH_CHECK_LOADED:-}" ]] && return 0
_ZBUILD_HEALTH_CHECK_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_HC_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_HC_ROOT/core/event-bus/event-bus.sh"

# ─── health_check_init ───────────────────────────────────────────────────────
health_check_init() {
    export ZBUILD_PLUGIN="health-check"
    export ZBUILD_PLUGIN_KIND="tool"
    emit_event "plugin.init.start" "plugin=health-check"
    return 0
}

# ─── health_check_run ────────────────────────────────────────────────────────
# Args: $1 = stage_id, $2 = state_file
# Stdout: raw probe output (HTTP response or error message).
# Exit code: 0 = healthy, non-zero = unhealthy.
health_check_run() {
    local stage_id="${1:-validate}"; : "$stage_id"
    local state_file="${2:-}"; : "$state_file"

    # Dry-run: emit mock success response without executing curl
    if [[ "${ZBUILD_DRY_RUN:-0}" == "1" ]]; then
        emit_event "validate.health_check.dry_run" "plugin=health-check"
        printf 'HTTP/1.1 200 OK\n'
        return 0
    fi

    local probe_url="${ZBUILD_HEALTH_CHECK_URL:-}"
    if [[ -z "$probe_url" ]]; then
        error "health-check: ZBUILD_HEALTH_CHECK_URL not set — no probe target"
        return 1
    fi
    # SSRF guard: only http/https schemes. Rejects file://, dict://, gopher://,
    # and other curl-honored schemes used to exfiltrate files or reach internal
    # services (#757 review finding). Host-level policy is the operator's (the
    # probe target is deliberately configured).
    if [[ ! "$probe_url" =~ ^https?:// ]]; then
        error "health-check: refusing non-http(s) probe URL: $probe_url"
        emit_event "validate.health_check.rejected" "plugin=health-check" "reason=scheme"
        return 1
    fi

    local probe_output probe_rc=0
    probe_output="$(curl -sf --max-time 30 "$probe_url" 2>&1)" || probe_rc=$?

    if [[ $probe_rc -eq 0 ]]; then
        emit_event "validate.health_check.pass" "plugin=health-check" "url=$probe_url"
        printf '%s\n' "$probe_output"
        return 0
    else
        emit_event "validate.health_check.fail" "plugin=health-check" "url=$probe_url" "rc=$probe_rc"
        printf '%s\n' "$probe_output"
        return "$probe_rc"
    fi
}

# ─── health_check_finalize ───────────────────────────────────────────────────
health_check_finalize() {
    emit_event "plugin.finalize.complete" "plugin=health-check"
    return 0
}

# ─── health_check_cleanup ────────────────────────────────────────────────────
health_check_cleanup() {
    return 0
}
