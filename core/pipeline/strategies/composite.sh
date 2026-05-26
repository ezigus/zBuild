#!/usr/bin/env bash
# core/pipeline/strategies/composite.sh — single-invocation multi-platform dispatch (issue #199/#222)
# ADR-009: one plugin call with ZBUILD_PLATFORMS=ios,node covering all platforms at once.
# Phase 1 deferred — the DAG-aware queen-collapse synthesis required by ruflo-hive
# is not yet implemented. This stub ensures a clear deferral message rather than
# a silent error.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_STRATEGY_COMPOSITE_LOADED:-}" ]] && return 0
_ZBUILD_STRATEGY_COMPOSITE_LOADED=1

# ─── _strategy_run_composite ─────────────────────────────────────────────────
# Usage: _strategy_run_composite <pool_id> <stage> <roles_out> <state_file> <plugins_root>
#
# Phase 1 stub (#311): refuses fail-loud rather than silently no-op'ing.
#
# A template selecting strategy: composite should be caught at the resolver
# layer; this entry point is the last line of defence. It:
#   1. Writes a clear error to stderr via `error` (not just `warn`).
#   2. Emits a structured `strategy.composite.unimplemented` event with
#      stable reason=phase1_deferred so logs are greppable.
#   3. Returns rc=1 so the caller treats the stage as a hard failure
#      instead of an empty success.
_strategy_run_composite() {
    local pool_id="$1" stage="${2:-unknown}"
    local platforms_csv platforms_len=0
    if declare -p _DETECTED_PLATFORMS >/dev/null 2>&1; then
        platforms_len="${#_DETECTED_PLATFORMS[@]}"
    fi
    if [[ "$platforms_len" -gt 0 ]]; then
        platforms_csv="$(IFS=,; echo "${_DETECTED_PLATFORMS[*]}")"
    else
        platforms_csv="${ZBUILD_PLATFORMS:-<unset>}"
    fi

    error "composite strategy not implemented (Phase 1, issue #199 + #311): stage=${stage} platforms=${platforms_csv}"

    # Best-effort event emission — event-bus may or may not be sourced by callers.
    if declare -F eb_emit_event >/dev/null 2>&1; then
        eb_emit_event "strategy.composite.unimplemented" \
            "stage=${stage}" \
            "platforms=${platforms_csv}" \
            "reason=phase1_deferred" 2>/dev/null || true
    elif declare -F emit_event >/dev/null 2>&1; then
        emit_event "strategy.composite.unimplemented" \
            "stage=${stage}" \
            "platforms=${platforms_csv}" \
            "reason=phase1_deferred" 2>/dev/null || true
    fi

    orch_shutdown "$pool_id" 2>/dev/null || true
    return 1
}
