#!/usr/bin/env bash
# plugins/tool/objective-gate/plugin.sh — Objective Gate Stage (ADR-037 §1, issue #969)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Runs the project test suite and lint/shellcheck. Hard-blocks (returns 1)
# on any non-zero exit. Writes verdict=fail|pass to objective-gate-result.json.
#
# Hook prefix: objective_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_OBJECTIVE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_OBJECTIVE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_OG_DIR="$_ZBUILD_PLUGIN_DIR"
_OG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_OG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_og_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── objective_gate_init ──────────────────────────────────────────────────────
objective_gate_init() {
    export ZBUILD_PLUGIN="objective-gate"
    export ZBUILD_PLUGIN_KIND="tool"
    _og_emit "plugin.init.start" "plugin=objective-gate"
    _og_emit "plugin.init.complete" "plugin=objective-gate"
    return 0
}

# ─── objective_gate_run ───────────────────────────────────────────────────────
# Hard-blocks on test suite or lint failure (returns 1); writes the artifact.
# Args: $1 = stage_id, $2 = state_file
objective_gate_run() {
    local stage_id="${1:-objective-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-og-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/objective-gate-result.json"
    local test_cmd="${ZBUILD_TEST_CMD:-npm test}"
    local lint_cmd="${ZBUILD_LINT_CMD:-npm run lint}"

    _og_emit "plugin.run.start" "plugin=objective-gate"

    local test_rc=0 lint_rc=0 fail_reason=""

    # Run test suite — T0 hard gate: any non-zero exit blocks merge.
    bash -c "$test_cmd" >/dev/null 2>&1 || test_rc=$?
    if [[ $test_rc -ne 0 ]]; then
        fail_reason="suite_fail"
        _og_emit "objective_gate.suite.fail" "exit_code=$test_rc"
    else
        _og_emit "objective_gate.suite.pass" "exit_code=0"
    fi

    # Run lint / shellcheck — always run even when suite failed so both results
    # are captured in the artifact for operator visibility.
    bash -c "$lint_cmd" >/dev/null 2>&1 || lint_rc=$?
    if [[ $lint_rc -ne 0 ]]; then
        [[ -z "$fail_reason" ]] && fail_reason="lint_fail"
        _og_emit "objective_gate.lint.fail" "exit_code=$lint_rc"
    else
        _og_emit "objective_gate.lint.pass" "exit_code=0"
    fi

    if [[ -n "$fail_reason" ]]; then
        printf '{"verdict":"fail","reason":"%s","test_rc":%d,"lint_rc":%d}\n' \
            "$fail_reason" "$test_rc" "$lint_rc" | atomic_write "$result_path"
        _og_emit "plugin.run.complete" "plugin=objective-gate" "verdict=fail"
        return 1
    fi

    printf '{"verdict":"pass","test_rc":0,"lint_rc":0}\n' | atomic_write "$result_path"
    _og_emit "plugin.run.complete" "plugin=objective-gate" "verdict=pass"
    return 0
}

# ─── objective_gate_finalize ──────────────────────────────────────────────────
objective_gate_finalize() {
    _og_emit "plugin.finalize.start" "plugin=objective-gate"
    _og_emit "plugin.finalize.complete" "plugin=objective-gate"
    return 0
}

# ─── objective_gate_cleanup ───────────────────────────────────────────────────
objective_gate_cleanup() {
    _og_emit "plugin.cleanup.start" "plugin=objective-gate"
    _og_emit "plugin.cleanup.complete" "plugin=objective-gate"
    return 0
}
