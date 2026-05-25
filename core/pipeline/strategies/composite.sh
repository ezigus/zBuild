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
# Phase 1 stub: always returns 1 with a deferral message.
_strategy_run_composite() {
    local pool_id="$1" stage="${2:-unknown}"
    warn "composite strategy not implemented (Phase 1, issue #199): stage=${stage}" || true
    orch_shutdown "$pool_id" 2>/dev/null || true
    return 1
}
