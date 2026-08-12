#!/usr/bin/env bash
# plugins/tool/teardown/plugin.sh — Teardown plugin (ADR-054 §7, issue #1829)
#
# Kind: tool  Tier: T0  (NO LLM calls — NEVER call route_to_model)
# Dispatched by the runner at every pipeline exit path with scope=release.
# Iterates over stages that executed (status=complete or status=failed) from
# pipeline-state.json and calls plugin_hook_call cleanup for each.
# A plugin with no cleanup hook returns 0 and emits `plugin.cleanup.absent`
# (#1823) — nothing to free is not a failure, so it needs no special case here.
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
# shellcheck source=../../../core/pipeline/dispatch.sh
# resolve_stage_plugin lives here; declare it rather than inherit the runner's
# scope — without it any other caller frees nothing and still returns 0.
source "$_ZBUILD_TEARDOWN_ROOT/core/pipeline/dispatch.sh"

# ─── teardown_run ────────────────────────────────────────────────────────────
# Entry point called by the pipeline engine.
# Usage: teardown_run <stage_id> <state_file>
# Scope is read from ZBUILD_TEARDOWN_SCOPE (default: release).
teardown_run() {
    local _stage_id="${1:-teardown}"
    local _state_file="${2:-}"

    # Fail-safe: an unrecognised scope degrades to `release`, the scope that
    # deletes nothing. The destructive scope is never the fallback.
    local _scope="${ZBUILD_TEARDOWN_SCOPE:-release}"
    case "$_scope" in
        release|purge) ;;
        *)
            emit_event "teardown.scope.invalid" \
                "requested=$_scope" "used=release" 2>/dev/null || true
            _scope="release"
            ;;
    esac
    local _plugins_root="${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_TEARDOWN_ROOT/plugins}"

    local _state_dir=""
    [[ -n "$_state_file" ]] && _state_dir="$(dirname "$_state_file")"

    # Read stages that executed (complete or failed) from pipeline-state.json.
    local -a _executed=()
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        local _s
        while IFS= read -r _s; do
            [[ -n "$_s" ]] && _executed+=("$_s")
        # NB: the durable key is `stage_statuses` and its values are plain
        # strings, not objects. Reading `.stages[].status` (which no state file
        # has ever had) yields an empty list, which makes teardown a silent
        # no-op that still reports success — verified against a real run's
        # pipeline-state.json before this was corrected.
        done < <(jq -r '
            .stage_statuses // {} |
            to_entries[] |
            select(.value == "complete" or .value == "failed") |
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

        # #1823: an absent cleanup hook now returns 0 (rc is binary — ADR-054 §4)
        # and records itself on `plugin.cleanup.absent`. The former
        # `[[ $_rc -eq $ZBUILD_HOOK_ABSENT ]] && continue` guard existed only to
        # keep rc=3 out of the failure branch below; with rc=0 that branch
        # already declines it, so the guard was dead weight and is gone. An
        # absent hook is still fully distinguishable from one that ran — on the
        # event, which is where #1828's acceptance asked for it.
        if [[ $_rc -ne 0 ]]; then
            emit_event "stage.cleanup.failed" \
                "stage=$_stage" "scope=$_scope" "rc=$_rc" 2>/dev/null || true
            _any_failed=1
        fi
    done

    emit_event "teardown.complete" \
        "scope=$_scope" "failed=$_any_failed" 2>/dev/null || true
    # Always return 0: cleanup failures are recorded via events, not propagated.
    return 0
}
