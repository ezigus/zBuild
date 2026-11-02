#!/usr/bin/env bash
# Tests: cycle orchestrator reads persisted current_iter and starts the
# iteration loop from that value (not 1) on resume. (issue #1805, ADR-006 §3.5)
#
# SPEC-7 [code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter
#   from persisted state at resume and starts the iteration loop from that value
#   (not 1); iter-1 complete stages emit no stage.start on resume into iter-2.
#   Its test must FAIL on the code as it was before this change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXT="$REPO_ROOT/tests/fixtures/templates"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "resume-loop-state — cycle orchestrator resumes from persisted iter (#1805)"
setup_test_env "resume-loop-state-1805"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../core/pipeline/cycle-orchestrator.sh
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../lib/cycle-report-stub.sh
source "$REPO_ROOT/tests/lib/cycle-report-stub.sh"

STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"

# ── SPEC-7: cycle starts from persisted current_iter on resume ─────────────────
print_test_section "[#1805/SPEC-7] cycle orchestrator resumes from current_iter (not 1)"

# Seed minimal state file required by _cycle_state_init.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Use zb_engine_loop_state to write one completed iteration (current_iter=1)
# into the state file. This simulates: iter-1 of the cycle has run and
# completed; the run was then interrupted before iter-2 dispatched.
# After the change the orchestrator will read current_iter=1 and start from
# iter-2 (current_iter + 1). Before the change it starts from iter=1.
zb_engine_loop_state "$STATE_FILE" "build-test" 1 5 "in_progress"

# Load the cycle template.
load_template "$FIXT/cycle-converges-iter2.yaml"

# Mock cycle_dispatch_stage: record the first iter dispatched, always pass.
# We record across all stages because the very first dispatch call reveals
# which iter the orchestrator started from.
_SPEC7_FIRST_ITER=-1
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$_SPEC7_FIRST_ITER" -eq -1 ]]; then
        _SPEC7_FIRST_ITER="$iter"
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

# The report stub makes the test member report zero test failures (pass).
zb_stub_reports_tests test

# Run the cycle orchestrator against the seeded state.
# Before this change: loop starts at iter=1 → first dispatch is iter=1.
# After this change: loop reads current_iter=1 → starts at iter=2 → first is 2.
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_rc=$?
set -e

# [#1805/SPEC-7]: first dispatched iter must be 2, not 1.
# Before the change: _SPEC7_FIRST_ITER=1 → assert 2==1 → FAILS.
# After the change:  _SPEC7_FIRST_ITER=2 → assert 2==2 → PASSES.
assert_eq \
    "[#1805/SPEC-7] first dispatched iter is 2 (resumed from current_iter=1, not restarted from 1)" \
    "2" "$_SPEC7_FIRST_ITER"

# [#1805/SPEC-7]: no cycle.iteration.complete event for iter=1
# (the orchestrator never ran iter-1, so it emits no completion for it).
_s7_iter1_complete=0
if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    _s7_iter1_complete="$(jq -r \
        'select(.type=="cycle.iteration.complete") | .data.iter // empty' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | grep -c '^1$' 2>/dev/null || echo 0)"
fi
assert_eq \
    "[#1805/SPEC-7] no cycle.iteration.complete for iter=1 (iter-1 was already done before resume)" \
    "0" "$_s7_iter1_complete"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "[#1805/SPEC-13] resume-loop-state test uses a fixture containing a cyclic stage"

# cycle-converges-iter2.yaml is loaded above via load_template and driven through
# cycle_orchestrator_run. Assert it contains type: cycle to formally pin the fixture
# contains a cyclic stage (as this test's SPEC-13 contract requires).
_s13_loop_fixt_content="$(cat "$FIXT/cycle-converges-iter2.yaml")"
assert_contains "[#1805/SPEC-13] cycle fixture used by resume-loop-state test has type: cycle" \
    "$_s13_loop_fixt_content" "type: cycle"

# Also assert the pipeline was actually run: cycle_dispatch_stage was invoked
# during cycle_orchestrator_run above, setting _SPEC7_FIRST_ITER from its
# initial -1.  A value > -1 proves the cyclic stage was dispatched.
assert_gt \
    "[#1805/SPEC-13] resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)" \
    "$_SPEC7_FIRST_ITER" "-1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
