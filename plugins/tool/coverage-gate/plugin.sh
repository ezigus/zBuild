#!/usr/bin/env bash
# plugins/tool/coverage-gate/plugin.sh — Coverage Read-out Gate (ADR-040, ADR-037 §1, #1135)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Thin read-out gate: consumes the SHARED test-framework result (test-results.json
# from the test stage, #1133) and NEVER re-runs the coverage tool. Reads the
# `coverage` block and maps it to a verdict:
#   - status skipped | error          → skip
#   - status below_floor              → fail
#   - status measured & pct < floor   → fail
#   - otherwise                       → pass
# Floor preference: the `floor` recorded in test-results.json wins; otherwise
# ZBUILD_COVERAGE_FLOOR (default 29). Absent file / missing block → skip. Writes
# verdict to coverage-result.json and always returns rc=0 (verdict-in-artifact).
#
# Hook prefix: coverage_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_COVERAGE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_COVERAGE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_cg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── _cg_lt ───────────────────────────────────────────────────────────────────
# Float-safe "a < b". Returns 0 (true) when both are numbers and a < b.
# Any non-numeric input → returns 1 (not-less), so a garbled pct never fails the
# gate spuriously. Usage: _cg_lt <a> <b>
_cg_lt() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)?$ && "$b" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    awk -v a="$a" -v b="$b" 'BEGIN { exit !(a < b) }'
}

# ─── coverage_gate_run ────────────────────────────────────────────────────────
# Reads $artifacts_dir/test-results.json, maps the .coverage block → verdict,
# emits coverage_gate.{pass,fail,skip}, writes coverage-result.json. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
coverage_gate_run() {
    local stage_id="${1:-coverage-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-coverage-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/coverage-result.json"
    local results_json="$artifacts_dir/test-results.json"

    # Read status, pct, floor in one jq pass. Absent file / block → all empty.
    # Try v2 path (.data.coverage) first; fall back to v1 top-level (.coverage)
    # for fixtures / older result files that predate the data block.
    local status="" pct="" floor=""
    if [[ -f "$results_json" ]]; then
        local _parsed
        _parsed="$(jq -r '(.data.coverage // .coverage) as $c |
            [($c.status // ""), ($c.pct // ""), ($c.floor // "")] | @tsv' \
            "$results_json" 2>/dev/null || echo)"
        IFS=$'\t' read -r status pct floor <<< "$_parsed"
    fi

    # Floor preference: recorded floor wins; otherwise the env default.
    [[ "$floor" =~ ^[0-9]+(\.[0-9]+)?$ ]] || floor="${ZBUILD_COVERAGE_FLOOR:-29}"

    local verdict detail=""
    case "$status" in
        below_floor)
            verdict="fail"
            detail="coverage below floor (pct=$pct floor=$floor)"
            _cg_emit "coverage_gate.fail" "detail=$detail"
            ;;
        measured)
            if _cg_lt "$pct" "$floor"; then
                verdict="fail"
                detail="coverage below floor (pct=$pct floor=$floor)"
                _cg_emit "coverage_gate.fail" "detail=$detail"
            else
                verdict="pass"
                detail="coverage $pct >= floor $floor"
                _cg_emit "coverage_gate.pass"
            fi
            ;;
        skipped | error)
            verdict="skip"
            detail="coverage $status"
            _cg_emit "coverage_gate.skip"
            ;;
        *)
            verdict="skip"
            detail="no coverage block in test-results.json"
            _cg_emit "coverage_gate.skip"
            ;;
    esac

    jq -n --arg v "$verdict" --arg s "$status" --arg p "$pct" --arg f "$floor" --arg d "$detail" \
        '{"verdict":$v,"status":$s,"pct":$p,"floor":$f,"detail":$d}' | atomic_write "$result_path"

    _cg_emit "plugin.result" "plugin=coverage-gate" "verdict=$verdict"
    return 0
}

# ─── coverage_gate_cleanup ────────────────────────────────────────────────────
coverage_gate_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second pair from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
