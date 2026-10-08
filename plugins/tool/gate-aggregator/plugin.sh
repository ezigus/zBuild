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
# artifact, mirrors shape-floor).
#
# Hook prefix: gate_aggregator_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_GATE_AGGREGATOR_LOADED:-}" ]] && return 0
_ZBUILD_GATE_AGGREGATOR_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
# shellcheck source=../../../scripts/lib/stage-summary.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/stage-summary.sh"
_GA_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_GA_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Manifest libs for ROSTER-DRIVEN discovery (ADR-040 §2): the must-pass set is
# derived at runtime from the cycle members' own `convergence:` markers — no
# hardcoded gate list — so adding/removing a gate needs NO edit to this plugin.
# shellcheck source=../../../scripts/lib/manifest-graph.sh
source "$_GA_ROOT/scripts/lib/manifest-graph.sh" 2>/dev/null || true
# yaml_get (top-level + single-level-nested scalar reader): convergence / role /
# provides.artifact_type. manifest-validation.sh is a leaf (sources nothing).
# shellcheck source=../../../core/plugin-registry/manifest-validation.sh
source "$_GA_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_ga_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# Legacy fallback must-pass set (ADR-040 §2, REGRESSION SAFETY). Used ONLY when
# no cycle roster is in scope — i.e. ZBUILD_CYCLE_ID / _TPL_CYCLE_STAGES_<id> are
# ABSENT (the aggregator invoked standalone with result files in a dir but no
# cycle env, as the unit tests do). The cycle path (see _ga_build_roster) learns
# the must-pass set from the present `convergence: gate` members instead.
# Format: "<gate_name>:<result_filename>", stable aggregation/reporting order.
_GA_LEGACY_MUST_PASS=(
    "suite:test-results.json"
    "shape-floor:shape-floor-result.json"
    "acceptance-gate:acceptance-gate-result.json"
    "lint:lint-result.json"
    "coverage:coverage-result.json"
    "mutation:mutation-result.json"
    "secret-scan:secret-scan-result.json"
)

# Populated by _ga_build_roster: "<name>:<result_filename>" entries (the order
# is the deterministic aggregation/reporting order). _GA_ROSTER_MODE records
# whether the roster came from the live cycle or the legacy fallback.
_GA_ROSTER=()
_GA_ROSTER_MODE=""

# ─── _ga_member_manifest / _ga_manifest_result_file ──────────────────────────
# Thin wrappers over the SHARED roster-resolution primitives in manifest-graph.sh
# (manifest_graph_resolve_member / manifest_graph_result_filename), so the
# gate-aggregator and the cycle engine's generic member-disposition contract
# resolve members identically (id-match then role binding; artifact_type then
# primary-output basename). Kept as named locals for readability at call sites.
_ga_member_manifest()      { manifest_graph_resolve_member "$1" "$2"; }
_ga_manifest_result_file() { manifest_graph_result_filename "$1"; }

# ─── _ga_build_roster <plugins_root> ─────────────────────────────────────────
# ADR-040 §2 roster-driven must-pass discovery. When a cycle is in scope
# (ZBUILD_CYCLE_ID set by cycle-orchestrator + _TPL_CYCLE_STAGES_<id> exported by
# template.sh), the must-pass set is every cycle member whose manifest declares
# `convergence: gate` — EXCLUDING the aggregator itself and any advisory/absent
# member. Otherwise FALL BACK to the legacy hardcoded set (cycle-less invocation,
# e.g. unit tests). Populates _GA_ROSTER + _GA_ROSTER_MODE.
_ga_build_roster() {
    local plugins_root="$1"
    _GA_ROSTER=()
    local cyc="${ZBUILD_CYCLE_ID:-}" stages=""
    if [[ -n "$cyc" ]]; then
        local stages_var="_TPL_CYCLE_STAGES_${cyc//-/_}"
        stages="${!stages_var:-}"
    fi
    if [[ -z "$stages" ]]; then
        _GA_ROSTER=("${_GA_LEGACY_MUST_PASS[@]}")
        _GA_ROSTER_MODE="fallback"
        return 0
    fi
    local IFS_save="$IFS"; IFS=','
    # shellcheck disable=SC2206
    local -a members=($stages)
    IFS="$IFS_save"
    local member manifest conv file
    for member in "${members[@]}"; do
        [[ -z "$member" ]] && continue
        [[ "$member" == "gate-aggregator" ]] && continue   # never aggregate self
        manifest="$(_ga_member_manifest "$plugins_root" "$member")" || continue
        conv="$(yaml_get "$manifest" "convergence" 2>/dev/null)"
        [[ "$conv" == "gate" ]] || continue                # advisory/absent excluded
        file="$(_ga_manifest_result_file "$manifest")" || continue
        [[ -z "$file" ]] && continue
        _GA_ROSTER+=("$member:$file")
    done
    # Safety net: a cycle that resolved to zero gates must NOT vacuously pass —
    # fall back to the legacy set so a misconfiguration fails closed, not open.
    if [[ ${#_GA_ROSTER[@]} -eq 0 ]]; then
        _GA_ROSTER=("${_GA_LEGACY_MUST_PASS[@]}")
        _GA_ROSTER_MODE="fallback"
    else
        _GA_ROSTER_MODE="cycle"
    fi
    return 0
}

# ─── _ga_read_gate_verdict ────────────────────────────────────────────────────
# Reads one gate's recorded verdict from its result artifact. Echoes a status
# token for the aggregate:
#   pass|skip      → the gate is satisfied (skip = ran, nothing to check)
#   advisory       → verdict=fail BUT the gate declared severity=advisory
#                    (generic member-disposition contract, ADR-021): a non-
#                    blocking failure (e.g. an infra flake) that must NOT block
#                    convergence. Satisfied for aggregation.
#   fail           → the gate blocked (verdict=fail, disposition terminal /
#                    recoverable / absent — the latter fail-closed)
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
        pass | skip) echo "$v" ;;
        fail | error)
            # severity=advisory demotes a fail to a non-blocking status so an
            # infra-flake never blocks convergence (recoverable/terminal/absent
            # stay blocking — recoverable drives another build iteration).
            # #2161: the word lives in `severity`.
            local disp
            # #1850: `severity` only — the v1 fallback to `disposition` is gone.
            disp="$(jq -r '.severity // ""' "$result_path" 2>/dev/null || echo "")"
            if [[ "$disp" == "advisory" ]]; then echo "advisory"; else echo "fail"; fi
            ;;
        *)           echo "malformed" ;;
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
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-$(zbuild_engine_tmpdir)/zbuild-gate-aggregator-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/gate-aggregator-result.json"
    local feedback_path="$artifacts_dir/gate-feedback.md"
    # A payload an older engine wrote; removed below, never read.
    local design_feedback_path="$artifacts_dir/design-feedback.md"

    # ADR-040 §2: discover the must-pass roster (cycle-driven or legacy fallback).
    local plugins_root="${ZBUILD_PLUGINS_ROOT:-$_GA_ROOT/plugins}"
    _ga_build_roster "$plugins_root"

    local verdict="pass"
    local failed=()         # gate names that blocked convergence
    local failed_files=()   # parallel to failed[]: the result filename
    local gate_pairs=()     # "name=status" for the artifact's gates map
    local entry name file status

    for entry in "${_GA_ROSTER[@]}"; do
        name="${entry%%:*}"
        file="${entry#*:}"
        status="$(_ga_read_gate_verdict "$artifacts_dir/$file")"
        gate_pairs+=("$name=$status")
        case "$status" in
            pass | skip | advisory) : ;;          # satisfied (advisory = non-blocking fail)
            *) verdict="fail"; failed+=("$name"); failed_files+=("$file") ;; # fail|missing|malformed
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

    # #2271 (ADR-068): one verdict for exit_when to bind to (ADR-040 §5). No
    # fault class — the engine no longer decides whose problem a failure is.
    local _ga_reason="all ${#gate_pairs[@]} gate(s) passed"
    if [[ "$verdict" != "pass" && ${#failed[@]} -gt 0 ]]; then
        _ga_reason="gates failed: $(printf '%s ' "${failed[@]}")"
        _ga_reason="${_ga_reason% }"
    fi
    jq -n --arg v "$verdict" --argjson g "$gates_json" --argjson f "$failed_json" \
        --arg r "$_ga_reason" \
        '{"result_contract":2,"verdict":$v,"disposition":"complete","reason":$r,"gates":$g,"failed":$f}' \
        | atomic_write "$result_path"

    # ─── #1988: the aggregator no longer renders prose ───────────────────────
    # It used to partition failed[] and write gate-feedback.md / design-feedback.md,
    # because it was the ONLY path for gate detail to reach a prompt — five gates
    # declared just a result JSON. #1976 made another path and #1988 gave each
    # gate its own `summary: true` detail output, so every failing gate now
    # speaks for itself, framed by its verdict.
    #
    # What remains here is what only this stage can do: ONE convergence verdict
    # for exit_when to bind to (ADR-040 §5).
    #
    # Stale payloads from a run on an older engine are removed rather than left
    # to be collected as current findings.
    rm -f "$feedback_path" "$design_feedback_path" 2>/dev/null || true

    # ADR-055 §9: this stage covers a roster, so its summary is the one the
    # engine ships — it must carry the roll-up the members no longer send.
    local _ga_failed_list="none"
    [[ ${#failed[@]} -gt 0 ]] && _ga_failed_list="$(printf '%s, ' "${failed[@]}")" && _ga_failed_list="${_ga_failed_list%, }"
    stage_summary_write "$artifacts_dir/gate-aggregator-summary.md" "gate-aggregator" "$verdict" \
        "rolled up ${#gate_pairs[@]} gate(s) into verdict $verdict" \
        "$(printf -- '- failed: %s' "$_ga_failed_list")"

    _ga_emit "plugin.result" "plugin=gate-aggregator" "verdict=$verdict"
    return 0
}

# ─── gate_aggregator_cleanup ──────────────────────────────────────────────────
