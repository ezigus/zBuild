#!/usr/bin/env bash
# plugins/tool/gate-aggregator/plugin.sh — Gate Aggregator (ADR-040 §2, #1137)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Collapses the mechanical gate stages into ONE convergence verdict — the single
# merge-blocking construct in the decomposed pipeline (ADR-040 §5). Reads each
# must-pass gate's recorded result artifact from the shared artifacts dir and
# aggregates: pass IFF every gate is PRESENT, well-formed, and verdict ∈
# {pass, skip}. FAIL-CLOSED (ADR-019, re-expressed by ADR-040): a missing /
# malformed REQUIRED gate, or any fail/error verdict → verdict=fail. Writes the
# verdict to gate-aggregator-result.json and ALWAYS returns 0 (verdict-in-
# artifact, mirrors objective-gate/shape-floor).
#
# Hook prefix: gate_aggregator_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_GATE_AGGREGATOR_LOADED:-}" ]] && return 0
_ZBUILD_GATE_AGGREGATOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_GA_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_GA_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_ga_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# Must-pass set (ADR-040 §1/§2): "<gate_name>:<result_filename>". The order is
# the stable, deterministic aggregation/reporting order.
_GA_MUST_PASS=(
    "suite:test-results.json"
    "shape-floor:shape-floor-result.json"
    "acceptance-gate:acceptance-gate-result.json"
    "lint:lint-result.json"
    "coverage:coverage-result.json"
    "mutation:mutation-result.json"
    "secret-scan:secret-scan-result.json"
)

# ─── gate_aggregator_init ─────────────────────────────────────────────────────
gate_aggregator_init() {
    export ZBUILD_PLUGIN="gate-aggregator"
    export ZBUILD_PLUGIN_KIND="tool"
    _ga_emit "plugin.init.start" "plugin=gate-aggregator"
    _ga_emit "plugin.init.complete" "plugin=gate-aggregator"
    return 0
}

# ─── _ga_read_gate_verdict ────────────────────────────────────────────────────
# Reads one gate's recorded verdict from its result artifact. Echoes a status
# token for the aggregate:
#   pass|skip      → the gate is satisfied (skip = ran, nothing to check)
#   fail           → the gate blocked
#   missing        → artifact absent (fail-closed: the gate did not run)
#   malformed      → artifact present but unparseable / no usable verdict
# The test stage's "error" verdict (interrupted / unparseable suite) maps to
# fail — an indeterminate suite must never satisfy convergence.
# Usage: _ga_read_gate_verdict <result_path>
_ga_read_gate_verdict() {
    local result_path="$1"
    [[ -f "$result_path" ]] || { echo "missing"; return 0; }
    local v
    v="$(jq -r '.verdict // empty' "$result_path" 2>/dev/null)" || { echo "malformed"; return 0; }
    case "$v" in
        pass | skip | fail) echo "$v" ;;
        error)              echo "fail" ;;
        *)                  echo "malformed" ;;
    esac
}

# ─── gate_aggregator_run ──────────────────────────────────────────────────────
# Aggregates the must-pass gate verdicts into a single convergence verdict.
# Writes gate-aggregator-result.json and ALWAYS returns 0.
# Args: $1 = stage_id, $2 = state_file
gate_aggregator_run() {
    local stage_id="${1:-gate-aggregator}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-gate-aggregator-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/gate-aggregator-result.json"

    _ga_emit "plugin.run.start" "plugin=gate-aggregator"

    local verdict="pass"
    local failed=()        # gate names that blocked convergence
    local gate_pairs=()     # "name=status" for the artifact's gates map
    local entry name file status

    for entry in "${_GA_MUST_PASS[@]}"; do
        name="${entry%%:*}"
        file="${entry#*:}"
        status="$(_ga_read_gate_verdict "$artifacts_dir/$file")"
        gate_pairs+=("$name=$status")
        case "$status" in
            pass | skip) : ;;                     # satisfied
            *) verdict="fail"; failed+=("$name") ;; # fail | missing | malformed
        esac
    done

    # Build the gates {name: status} object and the failed[] array via jq so the
    # JSON is well-formed regardless of gate-name content.
    local gates_json failed_json
    gates_json="$(printf '%s\n' "${gate_pairs[@]}" \
        | jq -R 'select(length>0) | (index("=") ) as $i | {(.[:$i]): .[$i+1:]}' \
        | jq -sc 'add // {}')"
    if [[ ${#failed[@]} -gt 0 ]]; then
        failed_json="$(printf '%s\n' "${failed[@]}" | jq -R . | jq -sc .)"
    else
        failed_json="[]"
    fi

    jq -n --arg v "$verdict" --argjson g "$gates_json" --argjson f "$failed_json" \
        '{"verdict":$v,"gates":$g,"failed":$f}' | atomic_write "$result_path"

    if [[ "$verdict" == "pass" ]]; then
        _ga_emit "gate_aggregator.pass"
    else
        _ga_emit "gate_aggregator.fail" "failed=${failed[*]}"
    fi

    _ga_emit "plugin.run.complete" "plugin=gate-aggregator" "verdict=$verdict"
    return 0
}

# ─── gate_aggregator_finalize ─────────────────────────────────────────────────
gate_aggregator_finalize() {
    _ga_emit "plugin.finalize.start" "plugin=gate-aggregator"
    _ga_emit "plugin.finalize.complete" "plugin=gate-aggregator"
    return 0
}

# ─── gate_aggregator_cleanup ──────────────────────────────────────────────────
gate_aggregator_cleanup() {
    _ga_emit "plugin.cleanup.start" "plugin=gate-aggregator"
    _ga_emit "plugin.cleanup.complete" "plugin=gate-aggregator"
    return 0
}
