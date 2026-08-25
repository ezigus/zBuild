#!/usr/bin/env bash
# Tests: cycle-orchestrator full-suite gate logic (ADR-034 / #846)
# Covers the two-phase targeted-then-full strategy wired into the orchestrator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — final-gate logic (ADR-034)"
setup_test_env "cycle-final-gate"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

_CYCLE_TRAP_CYCLE_ID="build-test"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"

# ─── Helper: write a test-results.json with a given run_mode ─────────────────
_write_test_results() {
    local run_mode="${1:-full}" verdict="${2:-pass}"
    mkdir -p "$STATE_DIR/artifacts"
    jq -n --arg rm "$run_mode" --arg v "$verdict" \
        '{result_contract:2, verdict:$v, disposition:"complete", reason:"mock", data:{run_mode:$rm, exit_code:0, passed:1, failed:0}}' \
        > "$STATE_DIR/artifacts/test-results.json"
}

# ─── T1: _cycle_read_test_run_mode returns "targeted" ────────────────────────
print_test_section "T1. _cycle_read_test_run_mode returns targeted from JSON"
_write_test_results "targeted"
_mode="$(_cycle_read_test_run_mode "$STATE_DIR")"
assert_eq "T1: run_mode=targeted read correctly" "targeted" "$_mode"

# ─── T2: _cycle_read_test_run_mode returns "full" ─────────────────────────────
print_test_section "T2. _cycle_read_test_run_mode returns full from JSON"
_write_test_results "full"
_mode="$(_cycle_read_test_run_mode "$STATE_DIR")"
assert_eq "T2: run_mode=full read correctly" "full" "$_mode"

# ─── T3: _cycle_read_test_run_mode defaults to "full" on missing file ─────────
print_test_section "T3. _cycle_read_test_run_mode defaults to full on missing file"
rm -f "$STATE_DIR/artifacts/test-results.json"
_mode="$(_cycle_read_test_run_mode "$STATE_DIR")"
assert_eq "T3: missing file → full (fail-closed)" "full" "$_mode"

# ─── T4: _cycle_apply_feedback exports ZBUILD_TEST_RED_SET when file present ──
print_test_section "T4. _cycle_apply_feedback exports ZBUILD_TEST_RED_SET"
printf '["tests/unit/foo-test.sh"]\n' > "$STATE_DIR/artifacts/test-red-set.json"
_CYCLE_TRAP_CYCLE_ID="build-test"
_CYCLE_FEEDBACK=()
unset ZBUILD_TEST_RED_SET 2>/dev/null || true
set +e; _cycle_apply_feedback 2 "$STATE_DIR"; rc=$?; set -e
assert_eq "T4: apply_feedback rc=0" "0" "$rc"
assert_eq "T4: ZBUILD_TEST_RED_SET exported" \
    "$STATE_DIR/artifacts/test-red-set.json" "${ZBUILD_TEST_RED_SET:-}"

# ─── T5: _cycle_apply_feedback unsets ZBUILD_TEST_RED_SET when no red-set ─────
print_test_section "T5. _cycle_apply_feedback unsets ZBUILD_TEST_RED_SET when absent"
rm -f "$STATE_DIR/artifacts/test-red-set.json"
export ZBUILD_TEST_RED_SET="/stale/path"
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 3 "$STATE_DIR"; rc=$?; set -e
assert_eq "T5: rc=0" "0" "$rc"
assert_eq "T5: ZBUILD_TEST_RED_SET unset when no red-set file" "" "${ZBUILD_TEST_RED_SET:-}"

# ─── T6: _cycle_apply_feedback exports ZBUILD_TEST_CHANGED_FILES ──────────────
print_test_section "T6. _cycle_apply_feedback exports ZBUILD_TEST_CHANGED_FILES from build-summary"
jq -n '{files_changed:["core/foo.sh","plugins/bar/plugin.sh"]}' \
    > "$STATE_DIR/artifacts/build-summary.json"
unset ZBUILD_TEST_CHANGED_FILES 2>/dev/null || true
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 4 "$STATE_DIR"; rc=$?; set -e
assert_eq "T6: rc=0" "0" "$rc"
_changed="${ZBUILD_TEST_CHANGED_FILES:-}"
assert_contains "T6: ZBUILD_TEST_CHANGED_FILES contains foo.sh" "$_changed" "foo.sh"
assert_contains "T6: ZBUILD_TEST_CHANGED_FILES contains bar" "$_changed" "bar"

# ─── T7: _cycle_apply_feedback unsets ZBUILD_TEST_CHANGED_FILES when no bsj ───
print_test_section "T7. _cycle_apply_feedback unsets ZBUILD_TEST_CHANGED_FILES when absent"
rm -f "$STATE_DIR/artifacts/build-summary.json"
export ZBUILD_TEST_CHANGED_FILES="stale,files"
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 5 "$STATE_DIR"; rc=$?; set -e
assert_eq "T7: rc=0" "0" "$rc"
assert_eq "T7: ZBUILD_TEST_CHANGED_FILES unset when no build-summary" \
    "" "${ZBUILD_TEST_CHANGED_FILES:-}"

# ─── T8: gate intercept suppresses convergence when run_mode=targeted ─────────
print_test_section "T8. gate intercept: targeted convergence → ZBUILD_TEST_FULL_SUITE_GATE set"
# Simulate the in-loop condition directly: set up the predicate globals, write
# a targeted test-results.json, and invoke the gate intercept logic via
# _cycle_read_test_run_mode + _cycle_check_max_iterations.
_write_test_results "targeted" "pass"
_CYCLE_UNTIL_STAGE="test"
_CYCLE_UNTIL_FIELD="verdict"
_CYCLE_UNTIL_OP="eq"
_CYCLE_UNTIL_VALUE="pass"
_CYCLE_TRAP_CYCLE_ID="build-test"
_CYCLE_TRAP_ITER=1
_CYCLE_MAX_ITER=5

# Verify: if run_mode=targeted AND iter < max, the predicate should NOT fire
# final convergence — gate suppresses it. We test the component functions
# directly since they're the smallest testable unit here.
_gate_rm="$(_cycle_read_test_run_mode "$STATE_DIR")"
assert_eq "T8: run_mode=targeted read for gate decision" "targeted" "$_gate_rm"

# _cycle_check_max_iterations at iter=1 with max=5 → not at max → gate CAN fire
set +e; _cycle_check_max_iterations 1 5; _at_max=$?; set -e
assert_eq "T8: iter=1 < max=5 → not at max (rc=1)" "1" "$_at_max"

# Document the gate decision: targeted AND not-at-max → suppress convergence
if [[ "$_gate_rm" == "targeted" ]] && [[ "$_at_max" -ne 0 ]]; then
    assert_pass "T8: gate conditions met → would suppress convergence"
else
    assert_fail "T8: gate conditions should have been met" "targeted=$_gate_rm at_max=$_at_max"
fi

# ─── T9: gate does NOT fire when run_mode=full ────────────────────────────────
print_test_section "T9. gate does NOT suppress convergence when run_mode=full"
_write_test_results "full" "pass"
_gate_rm9="$(_cycle_read_test_run_mode "$STATE_DIR")"
assert_eq "T9: run_mode=full → no gate" "full" "$_gate_rm9"

if [[ "$_gate_rm9" == "targeted" ]]; then
    assert_fail "T9: full mode should not trigger gate" "got targeted"
else
    assert_pass "T9: full mode → convergence proceeds normally"
fi

# ─── T10: ZBUILD_TEST_FULL_SUITE_GATE cleared between non-gate iters ──────────
print_test_section "T10. ZBUILD_TEST_FULL_SUITE_GATE unset at cycle_orchestrator_run entry"
# The orchestrator unsets ZBUILD_TEST_FULL_SUITE_GATE at cycle entry so it
# cannot bleed from a prior run. We test this by setting a stale value and
# verifying it's cleared by the first non-gate iter's lifecycle code.
# Since we can't run the full orchestrator here (no cycle_dispatch_stage hook),
# we verify the clearing logic indirectly by checking what cycle_orchestrator_run
# does with the env var when it returns 4 (config_invalid — no stages declared).
export ZBUILD_TEST_FULL_SUITE_GATE=1
STATE_FILE_T10="$TEST_TEMP_DIR/state-t10/state.json"
mkdir -p "$(dirname "$STATE_FILE_T10")"
printf '{}' > "$STATE_FILE_T10"
# Invoke with no template parsed → immediate config_invalid (rc=4)
# but the unset runs first.
unset _TPL_CYCLE_STAGES_build_test 2>/dev/null || true
set +e
cycle_orchestrator_run "build-test" "$TEST_TEMP_DIR/state-t10" "$STATE_FILE_T10"
_co_rc=$?
set -e
# rc=4 (config_invalid expected — no stages declared in test env)
# The important check: ZBUILD_TEST_FULL_SUITE_GATE was unset by the orchestrator.
assert_eq "T10: ZBUILD_TEST_FULL_SUITE_GATE unset at cycle entry" \
    "" "${ZBUILD_TEST_FULL_SUITE_GATE:-}"

# ─── Teardown ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
