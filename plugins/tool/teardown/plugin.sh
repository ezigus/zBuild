#!/usr/bin/env bash
# plugins/tool/teardown/plugin.sh — Teardown plugin (ADR-054 §7, issue #1829)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
# Dispatched by the runner at every pipeline exit path with scope=release.
# Iterates over stages that executed (status=complete or status=failed) from
# pipeline-state.json and calls plugin_hook_call cleanup for each.
# ZBUILD_HOOK_ABSENT (rc=3) from a plugin with no cleanup hook is a no-op.
# Always exits 0 — teardown failures are events, not verdict changes.

[[ -n "${_ZBUILD_TEARDOWN_LOADED:-}" ]] && return 0
_ZBUILD_TEARDOWN_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_ZBUILD_TEARDOWN_DIR="$_ZBUILD_PLUGIN_DIR"
_ZBUILD_TEARDOWN_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_ZBUILD_TEARDOWN_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/plugin-registry/registry.sh
source "$_ZBUILD_TEARDOWN_ROOT/core/plugin-registry/registry.sh"

# ─── teardown_run ────────────────────────────────────────────────────────────
# Entry point called by the pipeline engine.
# Usage: teardown_run <stage_id> <state_file>
# Scope is read from ZBUILD_TEARDOWN_SCOPE (default: release).
teardown_run() {
    local _stage_id="${1:-teardown}"
    local _state_file="${2:-}"

    local _scope="${ZBUILD_TEARDOWN_SCOPE:-release}"
    local _plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_TEARDOWN_ROOT/plugins}"

    local _state_dir=""
    [[ -n "$_state_file" ]] && _state_dir="$(dirname "$_state_file")"

    # Read stages that executed (complete or failed) from pipeline-state.json.
    local -a _executed=()
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        local _s
        while IFS= read -r _s; do
            [[ -n "$_s" ]] && _executed+=("$_s")
        done < <(jq -r '
            .stages // {} |
            to_entries[] |
            select(.value.status == "complete" or .value.status == "failed") |
            .key
        ' "$_state_file" 2>/dev/null || true)
    fi

    emit_event "teardown.start" \
        "scope=$_scope" "stage_count=${#_executed[@]}" 2>/dev/null || true

    local _any_failed=0
    local _stage _plugin_dir _rc
    for _stage in "${_executed[@]}"; do
        # Skip teardown itself to prevent circular cleanup dispatch.
        [[ "$_stage" == "teardown" ]] && continue

        _plugin_dir="$(resolve_stage_plugin "$_stage" "$_plugins_root" 2>/dev/null || true)"
        [[ -z "$_plugin_dir" ]] && continue

        _rc=0
        set +e
        plugin_hook_call "$_plugin_dir" cleanup "$_stage" "$_state_file" "$_scope"
        _rc=$?
        set -e

        # ZBUILD_HOOK_ABSENT=3 means no cleanup hook declared — supported no-op.
        [[ $_rc -eq "$ZBUILD_HOOK_ABSENT" ]] && continue

        if [[ $_rc -ne 0 ]]; then
            emit_event "stage.cleanup.release.failed" \
                "stage=$_stage" "scope=$_scope" "rc=$_rc" 2>/dev/null || true
            _any_failed=1
        fi
    done

    emit_event "teardown.complete" \
        "scope=$_scope" "failed=$_any_failed" 2>/dev/null || true
    # Always return 0: cleanup failures are recorded via events, not propagated.
    return 0
}
