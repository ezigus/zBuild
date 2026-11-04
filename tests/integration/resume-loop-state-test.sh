#!/usr/bin/env bash
# Tests: cycle orchestrator reads persisted current_iter and starts the
# iteration loop from that value (not 1) on resume. (issue #1805, ADR-006 §3.5)
#
# ITER-1 [code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter
#   from persisted state at resume and starts the iteration loop from that value
#   (not 1); iter-1 complete stages emit no stage.start on resume into iter-2;
#   the guard uses _ZBUILD_RESUME_ACTIVE so fresh runs and nested-loop re-entries
#   always start at iter=1. Its test must FAIL before this change.
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
print_test_section "[#1805/ITER-1] cycle orchestrator resumes from current_iter (not 1)"

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

# Mock cycle_dispatch_stage: record the first iter dispatched and whether iter=1
# was ever dispatched. We record across all stages because the very first
# dispatch call reveals which iter the orchestrator started from, and the
# _SPEC7_ITER1_DISPATCHED flag proves whether iter-1 stages were skipped.
_SPEC7_FIRST_ITER=-1
_SPEC7_ITER1_DISPATCHED=0
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$_SPEC7_FIRST_ITER" -eq -1 ]]; then
        _SPEC7_FIRST_ITER="$iter"
    fi
    if [[ "$iter" -eq 1 ]]; then
        _SPEC7_ITER1_DISPATCHED=1
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
export _ZBUILD_RESUME_ACTIVE=true
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_rc=$?
set -e

# [#1805/ITER-1]: first dispatched iter must be 2, not 1.
# Before the change: _SPEC7_FIRST_ITER=1 → assert 2==1 → FAILS.
# After the change:  _SPEC7_FIRST_ITER=2 → assert 2==2 → PASSES.
assert_eq \
    "[#1805/ITER-1] first dispatched iter is 2 (resumed from current_iter=1, not restarted from 1)" \
    "2" "$_SPEC7_FIRST_ITER"

# [#1805/ITER-1]: iter-1 stages must not be dispatched on resume into iter-2.
# cycle_dispatch_stage is the function that dispatches individual stages inside
# a cycle iteration; if any iter=1 stage were dispatched it would set this flag.
# Before the change: orchestrator starts at iter=1 → iter=1 stages dispatched →
#   _SPEC7_ITER1_DISPATCHED=1 → assert 0==1 → FAILS.
# After the change: starts at iter=2 → iter=1 never dispatched →
#   _SPEC7_ITER1_DISPATCHED=0 → PASSES.
assert_eq \
    "[#1805/ITER-1] iter-1 stages not dispatched on resume into iter-2 (complete iter skipped)" \
    "0" "$_SPEC7_ITER1_DISPATCHED"

# ── SPEC-7 clause 2b: nested-loop re-entry starts at iter=1 ─────────────────
# [#1805/ITER-1] clause 2b: a nested-loop re-entry (inner cycle called from within an outer
# cycle iteration) must start at iter=1, not from current_iter in state.
# Mechanism: the outer resume path consumes/clears _ZBUILD_RESUME_ACTIVE after using it,
# so any nested (inner) cycle call that follows sees the flag as cleared and starts at iter=1.
# This sub-test does NOT manually clear _ZBUILD_RESUME_ACTIVE — it relies on the outer
# cycle_orchestrator_run call above having consumed/cleared the flag. Re-seeding state with
# current_iter=1 and calling the orchestrator again simulates the nested invocation:
#   - Correct implementation (clears flag after outer use): starts at iter=1 → PASSES
#   - Incorrect implementation (keeps flag): starts at iter=2 → FAILS (regression detector)
# Before this change (no resume logic): always starts at 1 → passes trivially.
# After this change with correct flag consumption: flag cleared by outer call → PASSES.
# After this change without flag consumption: flag still true → starts at iter=2 → FAILS.
print_test_section "[#1805/ITER-1] nested-loop re-entry after outer resume starts at iter=1 (outer consumed flag)"

# Re-seed state: same current_iter=1 setup as the outer resume above.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
zb_engine_loop_state "$STATE_FILE" "build-test" 1 5 "in_progress"

# _ZBUILD_RESUME_ACTIVE is NOT manually cleared here.
# We check whatever state the outer cycle_orchestrator_run left the flag in.
_SPEC7_NESTED_FIRST_ITER=-1
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$_SPEC7_NESTED_FIRST_ITER" -eq -1 ]]; then
        _SPEC7_NESTED_FIRST_ITER="$iter"
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_nested_rc=$?
set -e

assert_eq \
    "[#1805/ITER-1] nested-loop re-entry starts at iter=1 (outer resume consumed/cleared _ZBUILD_RESUME_ACTIVE)" \
    "1" "$_SPEC7_NESTED_FIRST_ITER"

# ── SPEC-7 clause 3: _ZBUILD_RESUME_ACTIVE guard — fresh runs start at iter=1 ─
# [#1805/ITER-1] clause 3: without _ZBUILD_RESUME_ACTIVE=true, the orchestrator
# must start at iter=1 even when current_iter=1 is in state. This verifies the
# guard prevents the resume-path from affecting fresh runs and nested re-entries.
print_test_section "[#1805/ITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run always starts at iter=1"

# Re-seed state: same current_iter=1 as the resume test above, so that if the
# guard were absent, new code would start at iter=2 (making this assertion FAIL).
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
zb_engine_loop_state "$STATE_FILE" "build-test" 1 5 "in_progress"

# Unset the resume guard: simulates a fresh run (or a nested-loop re-entry).
unset _ZBUILD_RESUME_ACTIVE

_SPEC7_FRESH_FIRST_ITER=-1
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$_SPEC7_FRESH_FIRST_ITER" -eq -1 ]]; then
        _SPEC7_FRESH_FIRST_ITER="$iter"
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_fresh_rc=$?
set -e

# [#1805/ITER-1]: without _ZBUILD_RESUME_ACTIVE, the orchestrator must start at
# iter=1 even though current_iter=1 in state. This is the guard: fresh runs and
# nested-loop re-entries are NOT affected by resume-state iteration tracking.
# Old code (no resume logic): always starts at 1 → PASSES (guard trivially holds).
# New code with guard: unset → bypasses current_iter lookup → starts at 1 → PASSES.
# New code WITHOUT guard: would start at 2 → FAILS (regression detector).
assert_eq \
    "[#1805/ITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1 (guard prevents iter-skip)" \
    "1" "$_SPEC7_FRESH_FIRST_ITER"

# ── SPEC-13: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-loop-state test uses a fixture containing a cyclic stage"

# cycle-converges-iter2.yaml is loaded above via load_template and driven through
# cycle_orchestrator_run. Assert it contains type: cycle to formally pin the fixture
# contains a cyclic stage (as this test's SPEC-13 contract requires).
_s13_loop_fixt_content="$(cat "$FIXT/cycle-converges-iter2.yaml")"
assert_contains "cycle fixture used by resume-loop-state test has type: cycle" \
    "$_s13_loop_fixt_content" "type: cycle"

# Also assert the pipeline was actually run: cycle_dispatch_stage was invoked
# during cycle_orchestrator_run above, setting _SPEC7_FIRST_ITER from its
# initial -1.  A value > -1 proves the cyclic stage was dispatched.
assert_gt \
    "resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)" \
    "$_SPEC7_FIRST_ITER" "-1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
