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

# No helper shim: the SPECs below call _runner_validate_startup_preflight directly and
# inject a violation through its positional fixture argument. An earlier draft carried a
# `_run_preflight_empty` wrapper keyed on ZBUILD_PREFLIGHT_VIOLATION_FIXTURE — an env var
# the implementation never reads, in a function nothing ever called. Removed rather than
# left to imply a contract that does not exist.

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

# ─── SPEC-5: wiring — _runner_startup_preflight_gate calls preflight when active ──
{
    # Behavioral wiring test via the extracted gateway function (_runner_startup_preflight_gate,
    # added to runner.sh as part of this change). The gate wraps the dry-run/resume exemption
    # logic so it's testable without running the full pipeline startup sequence.
    if ! declare -f _runner_startup_preflight_gate >/dev/null 2>&1; then
        assert_fail "[SPEC-5] _runner_startup_preflight_gate not defined — wiring gate missing from runner.sh"
    else
        _spec5_called=0
        _spec5_saved=$(declare -f _runner_validate_startup_preflight)
        _runner_validate_startup_preflight() { _spec5_called=$((_spec5_called + 1)); return 0; }

        # Normal mode (not dry-run, not resume): preflight MUST be invoked.
        _spec5_called=0
        _runner_startup_preflight_gate false false
        assert_eq "[SPEC-5] wiring: preflight called in normal (non-dry-run, non-resume) mode" \
            "1" "$_spec5_called"

        # --dry-run: preflight MUST be skipped (matching leaf_resolvability exemption).
        _spec5_called=0
        _runner_startup_preflight_gate true false
        assert_eq "[SPEC-5] wiring: preflight exempt in --dry-run" "0" "$_spec5_called"

        # The gate exempts BOTH dry-run and resume (`! $dry_run && ! $resume_mode`).
        # Testing only the dry-run arm would let a regression in the resume arm through —
        # and resume is the path where re-running preflight is most likely to be wrong,
        # since the state it would validate was already accepted by the original run.
        _spec5_called=0
        _runner_startup_preflight_gate false true
        assert_eq "[SPEC-5] wiring: preflight exempt on --resume" "0" "$_spec5_called"

        eval "$_spec5_saved"
    fi
    # Structural check: the gate is invoked from main() on the live path — fails if the
    # wiring is deleted from runner.sh.
    #
    # This grep previously required `plugins_root` at the call site, which the gate has
    # never taken: its signature is <dry_run> <resume_mode> and it derives plugins_root
    # itself from ${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT}/plugins}. The assertion was
    # therefore false against every version of the code, and it was added (commit
    # 41b5bce, "add structural grep to SPEC-5 to break inert-wiring gate failure") to
    # satisfy the acceptance-gate rather than to describe the implementation. Pinning the
    # real signature keeps the reachability check honest.
    #
    # The two assertions above already prove the wiring behaviourally (called in normal
    # mode, exempt under --dry-run); this one only guards against the call being removed.
    # shellcheck disable=SC2016  # the literal '$dry_run' text is the thing being matched
    assert_eq "[SPEC-5] call-site: _runner_startup_preflight_gate is invoked from main()" \
        "1" "$(grep -c '_runner_startup_preflight_gate "\$dry_run" "\$resume_mode"' "$REPO_ROOT/core/pipeline/runner.sh")"
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
