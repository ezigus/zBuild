#!/usr/bin/env bash
# plugins/agent/cq-preflight — CQ pre-flight gates (ADR-013, issue #755)
# Hardened quality gates: bash-compat, coverage floor, untested-functions.
# Fail-fast: on any gate failure, writes verdict=fail and exits non-zero.
# legacy-citation: pipeline-intelligence.sh:2042-2195

[[ -n "${_ZBUILD_CQ_PREFLIGHT_LOADED:-}" ]] && return 0
_ZBUILD_CQ_PREFLIGHT_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_CQ_PREFLIGHT_ROOT="$_ZBUILD_PLUGIN_ROOT"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_CQ_PREFLIGHT_ROOT/core/event-bus/event-bus.sh"

_CQ_COVERAGE_THRESHOLD="${ZBUILD_CQ_COVERAGE_THRESHOLD:-60}"

cq_preflight_init() { return 0; }

cq_preflight_run() {
    local _state_file="$2"
    local _state_dir; _state_dir="$(dirname "$_state_file")"
    local _art_dir="$_state_dir/artifacts"
    mkdir -p "$_art_dir"

    local _verdict="pass"
    local -a _failures=()

    # Gate 1: bash 3.2 compatibility — detect bash 4+ constructs in diff
    # legacy-citation: pipeline-intelligence.sh:2042-2100
    if [[ -f "$_art_dir/diff.patch" ]]; then
        local _bad
        _bad="$(grep -E '^\+.*(declare -A|readarray|mapfile|\|\&|,, |,,}|,,[[:space:]])' \
            "$_art_dir/diff.patch" 2>/dev/null | grep -v '^+++' | head -5 || true)"
        if [[ -n "$_bad" ]]; then
            _failures+=("bash-compat: bash 4+ constructs detected in diff")
            _verdict="fail"
        fi
    fi

    # Gate 2: test coverage floor
    # legacy-citation: pipeline-intelligence.sh:2100-2150
    if [[ -f "$_art_dir/test-results.json" ]]; then
        local _cov
        _cov="$(jq -r '.coverage // empty' "$_art_dir/test-results.json" 2>/dev/null || true)"
        if [[ "$_cov" =~ ^[0-9]+$ ]] && (( _cov < _CQ_COVERAGE_THRESHOLD )); then
            _failures+=("coverage: ${_cov}% below threshold ${_CQ_COVERAGE_THRESHOLD}%")
            _verdict="fail"
        fi
    fi

    # Gate 3: new functions without tests
    # legacy-citation: pipeline-intelligence.sh:2150-2195
    if [[ -f "$_art_dir/diff.patch" && -f "$_art_dir/test-results.json" ]]; then
        local _new_fns _passed
        _new_fns="$(grep -cE '^\+[[:space:]]*(function[[:space:]]+)?[a-z_][a-z0-9_]*[[:space:]]*\(\)' \
            "$_art_dir/diff.patch" 2>/dev/null | tr -d ' ' || echo "0")"
        _passed="$(jq -r '.passed // 0' "$_art_dir/test-results.json" 2>/dev/null || echo "0")"
        if [[ "$_new_fns" =~ ^[0-9]+$ && "$_passed" =~ ^[0-9]+$ ]] \
           && (( _new_fns > 0 && _passed == 0 )); then
            _failures+=("untested: ${_new_fns} new function(s) with 0 passing tests")
            _verdict="fail"
        fi
    fi

    # Write canonical artifact
    local _fail_json="[]"
    if (( ${#_failures[@]} > 0 )); then
        _fail_json="$(printf '%s\n' "${_failures[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")"
    fi
    printf '{"verdict":"%s","gates":["bash_compat","coverage","untested_functions"],"failures":%s}\n' \
        "$_verdict" "$_fail_json" | atomic_write "$_art_dir/cq-preflight.json"

    eb_emit_event "plugin.run.complete" \
        "plugin=cq-preflight" "verdict=${_verdict}" 2>/dev/null || true

    [[ "$_verdict" == "pass" ]] && return 0 || return 1
}

cq_preflight_finalize() { return 0; }
cq_preflight_cleanup() { return 0; }
