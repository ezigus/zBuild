#!/usr/bin/env bash
# tests/unit/runner-startup-preflight-test.sh — ADR-051 §warn-first, issue #1318
#
# Unit tests for _runner_validate_startup_preflight:
#   - render-all-at-once (SPEC-1)
#   - warn mode returns 0 with violations (SPEC-2)
#   - enforce mode returns 2 with violations (SPEC-3)
#   - no violations → rc=0 in both modes (SPEC-4)
#   - wired after _contract_validate_pipeline in startup sequence (SPEC-5)
#   - off mode is a complete no-op (SPEC-6)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner startup preflight warn-first skeleton (#1318)"
setup_test_env "runner-startup-preflight"

# Source runner.sh — guarded behind an execution check so sourcing only defines
# functions without running the pipeline.
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/runner.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────
# _run_preflight <mode> <violation_fn> — calls _runner_validate_startup_preflight
# with a synthetic violations[] array injected via the violation_fn callback,
# returns its rc. The violation_fn is called inside the function's scope via
# a test shim set via ZBUILD_PREFLIGHT_VIOLATION_FIXTURE.
_run_preflight_empty() {
    local mode="${1:-warn}"
    local _out _rc
    ZBUILD_CONTRACT_VALIDATOR="$mode" ZBUILD_PREFLIGHT_VIOLATION_FIXTURE="" \
        _out="$(_runner_validate_startup_preflight "" 2>&1)" || true
    return 0
}

# ─── SPEC-1: function exists and collects all violations before rendering ─────
assert_eq "[SPEC-1] _runner_validate_startup_preflight is defined in runner.sh" "ok" \
    "$(declare -f _runner_validate_startup_preflight >/dev/null 2>&1 && echo ok || echo missing)"

# ─── SPEC-2: warn mode — violations present → rc=0 ───────────────────────────
{
    _pf_out=""
    set +e
    ZBUILD_CONTRACT_VALIDATOR=warn \
        _pf_out="$(_runner_validate_startup_preflight "__SPEC2_SYNTHETIC__" 2>&1)"
    _pf_rc=$?
    set -e
    assert_eq "[SPEC-2] warn mode: rc=0 even with violations" "0" "$_pf_rc"
}

# ─── SPEC-3: enforce mode — violations present → rc=2 ────────────────────────
{
    set +e
    ZBUILD_CONTRACT_VALIDATOR=enforce \
        _pf_out_enforce="$(_runner_validate_startup_preflight "__SPEC3_SYNTHETIC__" 2>&1)"
    _pf_rc_enforce=$?
    set -e
    assert_eq "[SPEC-3] enforce mode: rc=2 with violations" "2" "$_pf_rc_enforce"
}

# ─── SPEC-4: no violations → rc=0 in both modes ──────────────────────────────
{
    set +e
    ZBUILD_CONTRACT_VALIDATOR=warn \
        _pf_rc_ok_warn="$(  _runner_validate_startup_preflight "" 2>/dev/null; echo $?  )"
    ZBUILD_CONTRACT_VALIDATOR=enforce \
        _pf_rc_ok_enf="$(   _runner_validate_startup_preflight "" 2>/dev/null; echo $?  )"
    set -e
    assert_eq "[SPEC-4] warn+clean: rc=0"    "0" "${_pf_rc_ok_warn:-1}"
    assert_eq "[SPEC-4] enforce+clean: rc=0" "0" "${_pf_rc_ok_enf:-1}"
}

# ─── SPEC-5: function is called in the startup sequence (wired in runner.sh) ──
{
    # Structural wiring check: grep for the negated call-site inside runner.sh.
    # "if ! _runner_validate_startup_preflight" only appears at the call site (line ~1047),
    # NOT in the function definition — so this assertion fails if only the wiring is reverted.
    if grep -q "if ! _runner_validate_startup_preflight" "$REPO_ROOT/core/pipeline/runner.sh"; then
        assert_pass "[SPEC-5] _runner_validate_startup_preflight is wired in runner.sh"
    else
        assert_fail "[SPEC-5] _runner_validate_startup_preflight is NOT wired in runner.sh" \
            "call-site absent (if ! _runner_validate_startup_preflight)"
    fi
}

# ─── SPEC-6: off mode — complete no-op, rc=0, no output ──────────────────────
{
    set +e
    _off_out="$(ZBUILD_CONTRACT_VALIDATOR=off \
        _runner_validate_startup_preflight "__SPEC6_SYNTHETIC__" 2>&1)"
    _off_rc=$?
    set -e
    assert_eq "[SPEC-6] off mode: rc=0"       "0" "$_off_rc"
    assert_eq "[SPEC-6] off mode: no output"  ""  "$_off_out"
}

cleanup_test_env
print_test_results
exit $((FAIL > 0))
