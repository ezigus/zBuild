#!/usr/bin/env bash
# Tests: cycle-orchestrator ADR-034 wiring — the red-set/changed-files feedback
# export (#846) and, since #2144, the ABSENCE of the full-suite gate: the test
# stage confirms its own targeted pass, so the orchestrator reads no run mode
# and suppresses no convergence.
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
print_test_section "T6. _cycle_apply_feedback exports ZBUILD_TEST_CHANGED_FILES from the members' reports (#2189)"
_CYCLE_LAST_VERDICTS_BLOB='{"build":{"report":{"changes":{"files":["core/foo.sh","plugins/bar/plugin.sh"],"added":2,"removed":0}}}}'
unset ZBUILD_TEST_CHANGED_FILES 2>/dev/null || true
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 4 "$STATE_DIR"; rc=$?; set -e
assert_eq "T6: rc=0" "0" "$rc"
_changed="${ZBUILD_TEST_CHANGED_FILES:-}"
assert_contains "T6: ZBUILD_TEST_CHANGED_FILES contains foo.sh" "$_changed" "foo.sh"
assert_contains "T6: ZBUILD_TEST_CHANGED_FILES contains bar" "$_changed" "bar"

# ─── T7: _cycle_apply_feedback unsets ZBUILD_TEST_CHANGED_FILES when no bsj ───
print_test_section "T7. _cycle_apply_feedback unsets ZBUILD_TEST_CHANGED_FILES when absent"
_CYCLE_LAST_VERDICTS_BLOB='{}'
export ZBUILD_TEST_CHANGED_FILES="stale,files"
_CYCLE_FEEDBACK=()
set +e; _cycle_apply_feedback 5 "$STATE_DIR"; rc=$?; set -e
assert_eq "T7: rc=0" "0" "$rc"
assert_eq "T7: ZBUILD_TEST_CHANGED_FILES unset when no member reported changes" \
    "" "${ZBUILD_TEST_CHANGED_FILES:-}"

# ─── #2144: no run-mode reader, no gate, no suppression ──────────────────────
print_test_section "T8 [#2144]. the orchestrator has no run-mode reader and no full-suite gate"
if declare -F _cycle_read_test_run_mode >/dev/null 2>&1; then
    assert_fail "T8: _cycle_read_test_run_mode is gone" "still defined"
else
    assert_pass "T8: _cycle_read_test_run_mode is gone"
fi
# grep -c exits 1 on zero matches — the green case — so it must not trip errexit.
_gate_refs="$({ grep -c 'ZBUILD_TEST_FULL_SUITE_GATE\|full_suite_gate' \
    "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh" "$REPO_ROOT/plugins/tool/test/plugin.sh" \
    "$REPO_ROOT/config/event-schema.json" 2>/dev/null || true; } | awk -F: '{s+=$2} END {print s+0}')"
assert_eq "T8: no ZBUILD_TEST_FULL_SUITE_GATE / full_suite_gate reference remains in engine, plugin or schema" \
    "0" "$_gate_refs"

# Run 35412141973 (#1840): design_verify_cycle — no test member — spun to its
# max because build_test_cycle's iteration 2 had left `run_mode: targeted` in
# artifacts/test-results.json and the gate read it. A cycle whose members all
# pass converges on iteration 1 whatever a test artifact from elsewhere says.
print_test_section "T9 [#2144]. a stale run_mode=targeted artifact does not hold a cycle open"
# simple.yaml's design_verify_cycle is the cycle that spun: it has no test
# member, so nothing ever cleans a test artifact left by another cycle. The
# stub answers pass for every member (spec-coverage: covered).
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$REPO_ROOT/config/templates/simple.yaml"
STATE_T9="$TEST_TEMP_DIR/state-t9"
mkdir -p "$STATE_T9/artifacts"
printf '{"schema_version":1,"status":"in_progress"}' > "$STATE_T9/pipeline-state.json"
jq -n '{result_contract:2, verdict:"pass", disposition:"complete", reason:"mock",
        data:{run_mode:"targeted", exit_code:0, passed:1, failed:0}}' \
    > "$STATE_T9/artifacts/test-results.json"
cycle_dispatch_stage() {
    local stage="$1"
    _CYCLE_DISPATCH_VERDICT="pass"
    [[ "$stage" == "spec-coverage" ]] && _CYCLE_DISPATCH_VERDICT="covered"
    _CYCLE_DISPATCH_STATUS="complete"; return 0
}
: > "$ZBUILD_EVENTS_JSONL"
set +e
cycle_orchestrator_run "design_verify_cycle" "$STATE_T9" "$STATE_T9/pipeline-state.json" >/dev/null 2>&1
_rc_t9=$?
set -e
assert_eq "T9: the cycle converged (rc=0)" "0" "$_rc_t9"
assert_eq "T9: on iteration 1 — every member passed" "1" "${_CYCLE_LAST_ITERATIONS:-}"
assert_eq "T9: reason=converged" "converged" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_eq "T9: no cycle.test.full_suite_gate event" \
    "0" "$(grep -c 'cycle.test.full_suite_gate' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

# ─── Teardown ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
