#!/usr/bin/env bash
# plugins/tool/lint-gate/plugin.sh — Lint Read-out Gate (ADR-040, ADR-037 §1, #1135)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Thin read-out gate: consumes the SHARED test-framework result (test-results.json
# from the test stage, #1133) and NEVER re-runs the linter. Reads the `lint`
# block and maps lint.status → verdict (skipped→skip, fail→fail, pass→pass).
# Absent file or missing block → skip. Writes verdict to lint-result.json and
# always returns rc=0 (verdict-in-artifact, mirrors shape-floor).
#
# Hook prefix: lint_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_LINT_GATE_LOADED:-}" ]] && return 0
_ZBUILD_LINT_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_LG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_LG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_lg_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── lint_gate_run ────────────────────────────────────────────────────────────
# Reads $artifacts_dir/test-results.json, maps .lint.status → verdict, emits
# lint_gate.{pass,fail,skip}, writes lint-result.json. Always rc=0.
# Args: $1 = stage_id, $2 = state_file
lint_gate_run() {
    local stage_id="${1:-lint-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-lint-gate-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/lint-result.json"
    local results_json="$artifacts_dir/test-results.json"

    # Read the lint.status field. Absent file / missing block → "" → skip.
    local status=""
    if [[ -f "$results_json" ]]; then
        status="$(jq -r '.lint.status // empty' "$results_json" 2>/dev/null || echo)"
    fi

    local verdict detail=""
    case "$status" in
        fail)
            verdict="fail"
            detail="lint failed"
            _lg_emit "lint_gate.fail" "detail=$detail"
            ;;
        pass)
            verdict="pass"
            _lg_emit "lint_gate.pass"
            ;;
        skipped)
            verdict="skip"
            detail="lint skipped"
            _lg_emit "lint_gate.skip"
            ;;
        *)
            verdict="skip"
            detail="no lint block in test-results.json"
            _lg_emit "lint_gate.skip"
            ;;
    esac

    jq -n --arg v "$verdict" --arg s "$status" --arg d "$detail" \
        '{"verdict":$v,"status":$s,"detail":$d}' | atomic_write "$result_path"

    _lg_emit "plugin.result" "plugin=lint-gate" "verdict=$verdict"
    return 0
}

# ─── lint_gate_cleanup ────────────────────────────────────────────────────────
lint_gate_cleanup() {
    _lg_emit "plugin.cleanup.start" "plugin=lint-gate"
    _lg_emit "plugin.cleanup.complete" "plugin=lint-gate"
    return 0
}
