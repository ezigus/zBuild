#!/usr/bin/env bash
# Integration test: LLM CLI fail-fast behavior (#1024, ADR-028 amendment)
#
# Verifies that the file-backed consecutive-failure counter persists across
# sequential invocations within a shared pipeline run state dir, that the
# threshold-based abort (rc=9) fires at the right count, and that the
# terminal message carries the run_id and count for operator diagnosis.
#
# Integration concern: the counter is a FILE under ZBUILD_STATE_DIR — not a
# process-level variable — so it must accumulate correctly across calls that
# may execute in different subshells (the same invariant that plugin
# invocations inside a runner cycle exercise in production).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# Stub emit_event — framework calls it on every record/abort.
emit_event() { return 0; }

# shellcheck source=../../scripts/lib/llm-agent.sh
source "$REPO_ROOT/scripts/lib/llm-agent.sh"

print_test_header "LLM CLI fail-fast integration (#1024)"

setup_test_env "llm-cli-fail-fast"

# ─── Setup: isolated state dir (simulates a real pipeline run dir) ────────────
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/pipeline-state"
mkdir -p "$ZBUILD_STATE_DIR"
export ZBUILD_LLM_FAIL_THRESHOLD=2
export ZBUILD_RUN_ID="itest-fail-fast-$$"

# ─── I1 [SPEC-2]: counter accumulates across sequential calls → abort ─────────
# Two separate _zbuild_record_cli_fail calls (simulating two different plugin
# invocations sharing the same state dir) must reach the threshold and trigger
# rc=9. This is the core CHANGE behavior introduced by #1024.
_zbuild_reset_cli_fail
_zbuild_record_cli_fail   # simulates review-stage failure
_zbuild_record_cli_fail   # simulates test_assessment-stage failure

_llm_check_cli_fail_abort; _i1_rc=$?
assert_eq "[SPEC-2] counter accumulates across sequential records: two → rc=9" "9" "$_i1_rc"

# ─── I2 [SPEC-7]: single failure below threshold → no abort (guard) ──────────
# The abort must NOT fire after just one failure when threshold=2.
# This is the GUARD invariant: single transient CLI blip must not kill pipeline.
_zbuild_reset_cli_fail
_zbuild_record_cli_fail   # count=1, threshold=2 → no abort yet
_llm_check_cli_fail_abort; _i2_rc=$?
assert_eq "[SPEC-7] single failure below threshold=2 → rc=0 (no abort)" "0" "$_i2_rc"

# ─── I3 [SPEC-5]: abort message includes run_id and failure count ─────────────
# When the abort fires, the operator-visible message must contain both the
# run_id (for cross-referencing logs) and the failure count.
_zbuild_reset_cli_fail
_zbuild_record_cli_fail
_zbuild_record_cli_fail
_i3_msg="$(_llm_check_cli_fail_abort 2>&1 || true)"
assert_contains "[SPEC-5] abort message contains ZBUILD_RUN_ID" "$_i3_msg" "$ZBUILD_RUN_ID"
assert_contains "[SPEC-5] abort message contains failure count (2)" "$_i3_msg" "2"

# ─── I4: reset allows recovery (counter clears on success) ───────────────────
# After _zbuild_reset_cli_fail (called when a model call succeeds), the
# accumulated count is zero and abort must not fire.
_zbuild_reset_cli_fail
_llm_check_cli_fail_abort; _i4_rc=$?
assert_eq "I4: reset clears counter — subsequent abort check returns 0" "0" "$_i4_rc"

# ─── I5: custom ZBUILD_LLM_FAIL_THRESHOLD honored ────────────────────────────
# Operators can lower or raise the threshold via env. threshold=1 means even
# a single failure aborts; threshold=3 gives more retries.
_zbuild_reset_cli_fail
export ZBUILD_LLM_FAIL_THRESHOLD=1
_zbuild_record_cli_fail   # count=1 ≥ threshold=1 → abort immediately
_llm_check_cli_fail_abort; _i5_rc=$?
assert_eq "I5: threshold=1 → single failure triggers abort (rc=9)" "9" "$_i5_rc"
export ZBUILD_LLM_FAIL_THRESHOLD=2

# Restore so guard check below uses threshold=2.
_zbuild_reset_cli_fail

# ─── I6: counter file lives under ZBUILD_STATE_DIR (path contract) ──────────
_zbuild_reset_cli_fail
_zbuild_record_cli_fail
_counter_path="$(_zbuild_cli_fail_counter_path)"
if [[ -f "$_counter_path" ]]; then
    assert_pass "I6: counter file exists under ZBUILD_STATE_DIR"
    _counter_val="$(cat "$_counter_path" 2>/dev/null || echo 0)"
    assert_eq "I6: counter file contains count=1" "1" "$_counter_val"
else
    assert_fail "I6: counter file missing at expected path: $_counter_path"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
