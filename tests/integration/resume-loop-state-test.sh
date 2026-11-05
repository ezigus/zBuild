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

# ── [#1805/ITER-1] cycle starts from persisted current_iter on resume ─────────
print_test_section "[#1805/ITER-1] cycle orchestrator resumes from current_iter (not 1)"

# Given — a resume; persisted state records cycle_iterations[build-test].current_iter=2
#   (iter 1 completed before interruption); _ZBUILD_RESUME_ACTIVE=true is exported.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Use zb_engine_loop_state to write current_iter=2 into the state file.
# This simulates: iter 1 of the cycle completed; the run was interrupted before
# iter 2 dispatched. After the change the orchestrator reads current_iter=2 and
# starts from iter 2. Before the change it ignores state and starts from iter 1.
zb_engine_loop_state "$STATE_FILE" "build-test" 2 5 "in_progress"

# Load the cycle template.
load_template "$FIXT/cycle-converges-iter2.yaml"

# Mock cycle_dispatch_stage: record the first iter dispatched and whether iter=1
# was ever dispatched. cycle_dispatch_stage is the entry point for dispatching
# individual stages inside a cycle iteration; if any iter=1 stage were dispatched
# it would set _SPEC7_ITER1_DISPATCHED. Not being called for iter=1 is functionally
# equivalent to no stage.start being emitted for iter-1 stages in a unit-test context
# (cycle_dispatch_stage is what causes stage.start events to be emitted).
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

# When — _ZBUILD_RESUME_ACTIVE=true is exported and the cycle orchestrator's run
#   body executes. Before this change: loop starts at iter=1. After: reads
#   current_iter=2 and starts at iter 2.
set +e
export _ZBUILD_RESUME_ACTIVE=true
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_rc=$?
set -e

# Then — first dispatched iter must be 2, not 1.
# Before the change: orchestrator ignores current_iter, starts at iter=1 →
#   _SPEC7_FIRST_ITER=1 → assert 2==1 → FAILS.
# After the change: reads current_iter=2, starts at iter=2 →
#   _SPEC7_FIRST_ITER=2 → assert 2==2 → PASSES.
assert_eq \
    "[#1805/ITER-1] first dispatched iter is 2 (resumed from current_iter=2, not restarted from 1)" \
    "2" "$_SPEC7_FIRST_ITER"

# Then — iter-1 stages must not be dispatched on resume into iter-2.
# cycle_dispatch_stage is never called with iter=1 → _SPEC7_ITER1_DISPATCHED=0 → no
# stage.start events for iter-1 stages.
# Before the change: starts at iter=1 → iter-1 stages dispatched →
#   _SPEC7_ITER1_DISPATCHED=1 → assert 0==1 → FAILS.
# After the change: starts at iter=2 → iter-1 never dispatched →
#   _SPEC7_ITER1_DISPATCHED=0 → PASSES.
assert_eq \
    "[#1805/ITER-1] iter-1 stages not dispatched on resume into iter-2 (no stage.start for complete iter)" \
    "0" "$_SPEC7_ITER1_DISPATCHED"

# ── [#1805/ITER-1] clause 2b: nested-loop re-entry starts at iter=1 ──────────
# A nested-loop re-entry (inner cycle called from within an outer cycle iteration)
# must start at iter=1, not from current_iter in state.
# Mechanism: the outer resume path consumes/clears _ZBUILD_RESUME_ACTIVE after using it,
# so any nested (inner) cycle call that follows sees the flag as cleared and starts at iter=1.
# This sub-test does NOT manually clear _ZBUILD_RESUME_ACTIVE — it relies on the outer
# cycle_orchestrator_run call above having consumed/cleared the flag.
print_test_section "[#1805/ITER-1] nested-loop re-entry after outer resume starts at iter=1 (outer consumed flag)"

# Given — outer resume consumed _ZBUILD_RESUME_ACTIVE; persisted state records
#   cycle_iterations[build-test].current_iter=2 (same setup as above).
#   _ZBUILD_RESUME_ACTIVE is NOT manually cleared here — the outer call consumed it.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
zb_engine_loop_state "$STATE_FILE" "build-test" 2 5 "in_progress"

# _ZBUILD_RESUME_ACTIVE is intentionally not set here.
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

# When — cycle_orchestrator_run executes (simulating a nested-loop re-entry after
#   the outer resume consumed the resume flag).
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_nested_rc=$?
set -e

# Then — nested-loop re-entry starts at iter=1 (outer resume consumed/cleared flag).
# Correct implementation (clears flag after outer use): starts at iter=1 → PASSES.
# Incorrect implementation (keeps flag active): starts at iter=2 → FAILS (regression detector).
# Before this change (no resume logic): always starts at 1 → passes trivially.
assert_eq \
    "[#1805/ITER-1] nested-loop re-entry starts at iter=1 (outer resume consumed/cleared _ZBUILD_RESUME_ACTIVE)" \
    "1" "$_SPEC7_NESTED_FIRST_ITER"

# ── [#1805/ITER-1] clause 3: _ZBUILD_RESUME_ACTIVE guard — fresh runs start at iter=1 ─
# Without _ZBUILD_RESUME_ACTIVE=true, the orchestrator must start at iter=1 even
# when current_iter=2 is in state. This verifies the guard prevents the resume-path
# from affecting fresh runs and nested re-entries.
print_test_section "[#1805/ITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run always starts at iter=1"

# Given — _ZBUILD_RESUME_ACTIVE is unset (fresh run); persisted state records
#   cycle_iterations[build-test].current_iter=2. If the guard is absent, new code
#   would read current_iter=2 and start at iter=2 → assertion fails.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
zb_engine_loop_state "$STATE_FILE" "build-test" 2 5 "in_progress"

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

# When — cycle_orchestrator_run executes with no resume flag (fresh run).
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_fresh_rc=$?
set -e

# Then — without _ZBUILD_RESUME_ACTIVE, the orchestrator starts at iter=1 even
# though current_iter=2 is in state. Guard prevents resume-state affecting fresh runs.
# Old code (no resume logic): always starts at 1 → PASSES (guard trivially holds).
# New code with guard: unset → bypasses current_iter lookup → starts at 1 → PASSES.
# New code WITHOUT guard: would start at 2 → FAILS (regression detector).
assert_eq \
    "[#1805/ITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1 (guard prevents iter-skip)" \
    "1" "$_SPEC7_FRESH_FIRST_ITER"

# ── CYCL-1: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-loop-state test uses a fixture containing a cyclic stage"

# cycle-converges-iter2.yaml is loaded above via load_template and driven through
# cycle_orchestrator_run. Assert it contains type: cycle to formally pin the fixture
# contains a cyclic stage (as CYCL-1 requires).
_s13_loop_fixt_content="$(cat "$FIXT/cycle-converges-iter2.yaml")"
assert_contains "cycle fixture used by resume-loop-state test has type: cycle" \
    "$_s13_loop_fixt_content" "type: cycle"

# Also assert the pipeline was actually run: cycle_dispatch_stage was invoked
# during cycle_orchestrator_run above, setting _SPEC7_FIRST_ITER from its
# initial -1. A value > -1 proves the cyclic stage was dispatched.
assert_gt \
    "resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)" \
    "$_SPEC7_FIRST_ITER" "-1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
