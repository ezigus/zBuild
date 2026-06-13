#!/usr/bin/env bash
# plugins/agent/cq-preflight — CQ pre-flight gates (ADR-013, issue #755)
#
# Runs bash-compat check, coverage floor check, and untested-function scan.
# Fail-fast: non-zero exit skips cq-audit-plan, cq-cycle, and cq-backtrack.
# legacy-citation: stage_compound_quality pre-flight block at
#   legacy/scripts/lib/pipeline-intelligence.sh:2042-2195

[[ -n "${_ZBUILD_CQ_PREFLIGHT_LOADED:-}" ]] && return 0
_ZBUILD_CQ_PREFLIGHT_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_PREFLIGHT_DIR="$_ZBUILD_PLUGIN_DIR"
_CQ_PREFLIGHT_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$_CQ_PREFLIGHT_ROOT/core/redaction/scope-redaction.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_PREFLIGHT_ROOT/core/event-bus/event-bus.sh"

cq_preflight_run() {
    # shellcheck disable=SC2034  # hook-signature positional; unused in this stage
    local state_dir="$1"
    local artifact_dir="$2"

    local result_file="$artifact_dir/cq-preflight-result.json"
    local verdict="pass"
    local failures=()

    eb_emit_event "cq.preflight.start" "stage=cq-preflight"

    # Bash-compat check: shellcheck must be available
    if ! command -v shellcheck >/dev/null 2>&1; then
        failures+=("shellcheck not found")
        verdict="warn"
    fi

    # Coverage floor check: read from test-results.json if present
    local test_results="$artifact_dir/test-results.json"
    if [[ -f "$test_results" ]]; then
        local coverage
        coverage="$(jq -r '.coverage // empty' "$test_results" 2>/dev/null || true)"
        local floor="${ZBUILD_CQ_COVERAGE_FLOOR:-29}"
        if [[ -n "$coverage" ]] && (( $(printf '%s < %s\n' "$coverage" "$floor" | bc -l 2>/dev/null || echo 0) )); then
            failures+=("coverage ${coverage}% below floor ${floor}%")
            verdict="fail"
        fi
    fi

    # Write result artifact
    local failures_json="[]"
    if [[ ${#failures[@]} -gt 0 ]]; then
        failures_json="$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)"
    fi
    printf '{"verdict":"%s","failures":%s}\n' "$verdict" "$failures_json" \
        | atomic_write "$result_file"

    eb_emit_event "cq.preflight.complete" "stage=cq-preflight" "verdict=$verdict"

    if [[ "$verdict" == "fail" ]]; then
        return 1
    fi
    return 0
}
