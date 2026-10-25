#!/usr/bin/env bash
# plugins/tool/coverage-gate/plugin.sh — Coverage Read-out Gate (ADR-040, ADR-037 §1, #1135)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Thin read-out gate: consumes the SHARED test-framework result (the test run
# from the test stage, #1133) and NEVER re-runs the coverage tool. Reads the
# `coverage` block and maps it to a verdict:
#   - status skipped | error          → skip
#   - status below_floor              → fail
#   - status measured & pct < floor   → fail
#   - otherwise                       → pass
# Floor preference: the `floor` recorded in the test run wins; otherwise
# ZBUILD_COVERAGE_FLOOR (default 29). Absent file / missing block → skip. Writes
# verdict to coverage-result.json and always returns rc=0 (verdict-in-artifact).
#
# Hook prefix: coverage_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_COVERAGE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_COVERAGE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
# NOT `|| true`: this helper is how the gate's findings reach a prompt at
# all. Swallowing a failed load would leave stage_summary_write undefined and
# every finding silently unpublished — the exact shape #1991 guards.
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-summary.sh"
# #2366 (ADR-054 §6): the one result writer — contract 3, one outcome.
# shellcheck source=../../../scripts/lib/stage-result.sh
source "$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null || true; pwd)/../../../scripts/lib/stage-result.sh"
_CG_ROOT="$_ZBUILD_PLUGIN_ROOT"
# #2364: earlier work is found by what it contains, never by which stage made it.
# shellcheck source=../../../scripts/lib/earlier-output.sh
source "$_CG_ROOT/scripts/lib/earlier-output.sh"

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
# Resolves test_results from ZBUILD_STAGE_INPUTS when set, otherwise reads
# the test run (found by content, #2364). Maps the .coverage block → verdict, emits
# coverage_gate.{pass,fail,skip}, writes coverage-result.json. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
coverage_gate_run() {
    local stage_id="${1:-coverage-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$(zbuild_engine_tmpdir)/zbuild-coverage-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/coverage-result.json"
    # #2364: the test run that carries a coverage block, found by what it carries.
    local results_json
    results_json="$(earlier_output_with_json '(.data.coverage // .coverage) != null' "${artifact_dir:-${artifacts_dir:-${art:-}}}" "${state_dir:-}" 2>/dev/null || true)"

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

    # #2366: one outcome — nothing to check is a pass, its reason says so.
    local outcome detail=""
    case "$status" in
        below_floor)
            outcome="fail"
            detail="coverage below floor (pct=$pct floor=$floor)"
            _cg_emit "coverage_gate.fail" "detail=$detail"
            ;;
        measured)
            if _cg_lt "$pct" "$floor"; then
                outcome="fail"
                detail="coverage below floor (pct=$pct floor=$floor)"
                _cg_emit "coverage_gate.fail" "detail=$detail"
            else
                outcome="pass"
                detail="coverage $pct >= floor $floor"
                _cg_emit "coverage_gate.pass"
            fi
            ;;
        skipped | error)
            outcome="pass"
            detail="coverage $status"
            _cg_emit "coverage_gate.skip"
            ;;
        *)
            outcome="pass"
            detail="no coverage block in any test run"
            _cg_emit "coverage_gate.skip"
            ;;
    esac

    stage_result_write "$result_path" "$outcome" "$detail" \
        "$(jq -nc --arg s "$status" --arg p "$pct" --arg f "$floor" '{status:$s, pct:$p, floor:$f}')"
    # #1988: publish what only this gate knows. Its detail used to reach a
    # prompt only through the aggregator's rendering; it is now a declared
    # summary output (#1976), and cleared on a non-fail so a stale file from a
    # previous iteration never renders as a current finding.
    stage_summary_write "$artifacts_dir/coverage-detail.md" "coverage" "$outcome" "$detail"

    _cg_emit "plugin.result" "plugin=coverage-gate" "verdict=$outcome"
    return 0
}

# ─── coverage_gate_cleanup ────────────────────────────────────────────────────
