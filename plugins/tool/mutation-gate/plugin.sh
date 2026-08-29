#!/usr/bin/env bash
# plugins/tool/mutation-gate/plugin.sh — Mutation Read-out Gate (ADR-040, ADR-037 §1, #1135)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Thin read-out gate: consumes the SHARED test-framework result (test-results.json
# from the test stage, #1133) and NEVER re-runs the mutation harness. Reads the
# `mutation` block and maps it to a verdict:
#   - status skipped              → skip
#   - score "N/M", N < floor      → fail
#   - otherwise                   → pass
# Floor preference: the `floor` recorded in test-results.json wins; otherwise
# ZBUILD_MUTATION_FLOOR (default 0). Absent file / missing block → skip. Writes
# verdict to mutation-result.json and always returns rc=0 (verdict-in-artifact).
#
# Hook prefix: mutation_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_MUTATION_GATE_LOADED:-}" ]] && return 0
_ZBUILD_MUTATION_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_MG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_MG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_mg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── mutation_gate_run ────────────────────────────────────────────────────────
# Reads $artifacts_dir/test-results.json, parses the .mutation block ("N/M"
# score + floor) → verdict, emits mutation_gate.{pass,fail,skip}, writes
# mutation-result.json. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
mutation_gate_run() {
    local stage_id="${1:-mutation-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-mutation-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/mutation-result.json"
    local results_json="$artifacts_dir/test-results.json"

    # Read status, score, floor in one jq pass. Absent file / block → all empty.
    # Try v2 path (.data.mutation) first; fall back to v1 top-level (.mutation)
    # for fixtures / older result files that predate the data block.
    local status="" score="" floor=""
    if [[ -f "$results_json" ]]; then
        local _parsed
        _parsed="$(jq -r '(.data.mutation // .mutation) as $m |
            [($m.status // ""), ($m.score // ""), ($m.floor // "")] | @tsv' \
            "$results_json" 2>/dev/null || echo)"
        IFS=$'\t' read -r status score floor <<< "$_parsed"
    fi

    # Floor preference: recorded integer floor wins; otherwise the env default.
    [[ "$floor" =~ ^-?[0-9]+$ ]] || floor="${ZBUILD_MUTATION_FLOOR:-0}"

    local verdict detail=""
    case "$status" in
        measured)
            # Parse the killed/passed count N from "N/M".
            local killed=""
            if [[ "$score" =~ ^([0-9]+)/([0-9]+)$ ]]; then
                killed="${BASH_REMATCH[1]}"
            fi
            if [[ -n "$killed" ]] && (( killed < floor )); then
                verdict="fail"
                detail="mutation score below floor (score=$score floor=$floor)"
                _mg_emit "mutation_gate.fail" "detail=$detail"
            else
                verdict="pass"
                detail="mutation score $score >= floor $floor"
                _mg_emit "mutation_gate.pass"
            fi
            ;;
        skipped)
            verdict="skip"
            detail="mutation skipped"
            _mg_emit "mutation_gate.skip"
            ;;
        *)
            verdict="skip"
            detail="no mutation block in test-results.json"
            _mg_emit "mutation_gate.skip"
            ;;
    esac

    jq -n --arg v "$verdict" --arg s "$status" --arg sc "$score" --arg f "$floor" --arg d "$detail" \
        '{"verdict":$v,"status":$s,"score":$sc,"floor":$f,"detail":$d}' | atomic_write "$result_path"

    _mg_emit "plugin.result" "plugin=mutation-gate" "verdict=$verdict"
    return 0
}

# ─── mutation_gate_cleanup ────────────────────────────────────────────────────
mutation_gate_cleanup() {
    # No self-emit (#1705): plugin_hook_call already brackets this hook with
    # plugin.cleanup.start/complete. A second pair from here is the same
    # two-emitters-one-name collision the run pair was filed for.
    return 0
}
