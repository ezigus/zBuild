#!/usr/bin/env bash
# Tests: cycle orchestrator reads persisted current_iter and starts the
# iteration loop from that value (not 1) on resume. (issue #1805, ADR-006 §3.5)
#
# DSITER-1 [code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter
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

# ── [#1805/DSITER-1] cycle starts from persisted current_iter on resume ─────────
print_test_section "[#1805/DSITER-1] cycle orchestrator resumes from current_iter (not 1)"

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

# Given — _ZBUILD_RESUME_ACTIVE=true is exported (the resume flag set by the runner
#   before invoking the cycle orchestrator on a resume path).
export _ZBUILD_RESUME_ACTIVE=true

# When — the cycle orchestrator's run body executes. Before this change: loop
#   starts at iter=1. After: reads current_iter=2 and starts at iter 2.
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7_rc=$?
set -e

# Then — first dispatched iter must be 2, not 1.
# Before the change: orchestrator ignores current_iter, starts at iter=1 →
#   _SPEC7_FIRST_ITER=1 → assert 2==1 → FAILS.
# After the change: reads current_iter=2, starts at iter=2 →
#   _SPEC7_FIRST_ITER=2 → assert 2==2 → PASSES.
assert_eq \
    "[#1805/DSITER-1] first dispatched iter is 2 (resumed from current_iter=2, not restarted from 1)" \
    "2" "$_SPEC7_FIRST_ITER"

# Then — iter-1 stages must not be dispatched on resume into iter-2.
# cycle_dispatch_stage is never called with iter=1 → _SPEC7_ITER1_DISPATCHED=0 → no
# stage.start events for iter-1 stages.
# Before the change: starts at iter=1 → iter-1 stages dispatched →
#   _SPEC7_ITER1_DISPATCHED=1 → assert 0==1 → FAILS.
# After the change: starts at iter=2 → iter-1 never dispatched →
#   _SPEC7_ITER1_DISPATCHED=0 → PASSES.
assert_eq \
    "[#1805/DSITER-1] iter-1 stages not dispatched on resume into iter-2 (no stage.start for complete iter)" \
    "0" "$_SPEC7_ITER1_DISPATCHED"

# ── [#1805/DSITER-1] clause 2b: nested-loop re-entry starts at iter=1 ──────────
# A nested-loop re-entry (inner cycle called from within an outer cycle iteration)
# must start at iter=1, not from current_iter in state.
# Mechanism: the outer resume path consumes/clears _ZBUILD_RESUME_ACTIVE after using it,
# so any nested (inner) cycle call that follows sees the flag as cleared and starts at iter=1.
# This sub-test does NOT manually clear _ZBUILD_RESUME_ACTIVE — it relies on the outer
# cycle_orchestrator_run call above having consumed/cleared the flag.
print_test_section "[#1805/DSITER-1] nested-loop re-entry after outer resume starts at iter=1 (outer consumed flag)"

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
    "[#1805/DSITER-1] nested-loop re-entry starts at iter=1 (outer resume consumed/cleared _ZBUILD_RESUME_ACTIVE)" \
    "1" "$_SPEC7_NESTED_FIRST_ITER"

# ── [#1805/DSITER-1] clause 3: _ZBUILD_RESUME_ACTIVE guard — fresh runs start at iter=1 ─
# Without _ZBUILD_RESUME_ACTIVE=true, the orchestrator must start at iter=1 even
# when current_iter=2 is in state. This verifies the guard prevents the resume-path
# from affecting fresh runs and nested re-entries.
print_test_section "[#1805/DSITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run always starts at iter=1"

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
    "[#1805/DSITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1 (guard prevents iter-skip)" \
    "1" "$_SPEC7_FRESH_FIRST_ITER"

# ── [#1805/DSITER-1] write side: current_iter persisted before first dispatch ─────
# The read-side tests above pre-seed current_iter=2 and verify the orchestrator
# READS it. This sub-case verifies the WRITE side: at the moment
# cycle_dispatch_stage is first called for iter=1 on a fresh run, current_iter=1
# must already be in the state file (written by _cycle_state_write_iter_start).
# Without _cycle_state_write_iter_start the value would remain at its init value
# (0 / absent) at dispatch time and this assertion would FAIL.
print_test_section "[#1805/DSITER-1] write side: current_iter=1 persisted in state before first cycle_dispatch_stage call"

# Given — a fresh run (no resume); state file has no prior cycle iterations;
#   _ZBUILD_RESUME_ACTIVE is unset so this exercises the fresh-run write path.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"
load_template "$FIXT/cycle-converges-iter2.yaml"
unset _ZBUILD_RESUME_ACTIVE

# When the orchestrator runs, capture current_iter from the state file at the
# moment cycle_dispatch_stage is first called. This pins write-before-dispatch.
_SPEC7W_CURRENT_ITER_AT_FIRST_DISPATCH=-99
_SPEC7W_FIRST_DISPATCH_SEEN=0
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$_SPEC7W_FIRST_DISPATCH_SEEN" -eq 0 ]]; then
        _SPEC7W_FIRST_DISPATCH_SEEN=1
        _SPEC7W_CURRENT_ITER_AT_FIRST_DISPATCH="$(jq -r \
            '.cycle_iterations["build-test"].current_iter // -99' \
            "$STATE_FILE" 2>/dev/null || echo "-99")"
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

zb_stub_reports_tests test

# When — cycle orchestrator runs a fresh iteration 1 (no resume).
set +e
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_s7w_rc=$?
set -e

# Then — at the moment cycle_dispatch_stage was first called for iter=1,
# current_iter in the state file was already 1.
# If _cycle_state_write_iter_start is removed: current_iter stays at init value
# (0 → or absent → -99 fallback) → assert "1" == "0" or "1" == "-99" → FAILS.
# After the change: _cycle_state_write_iter_start writes current_iter=1 before
# cycle_dispatch_stage is called → assert "1" == "1" → PASSES.
assert_eq \
    "[#1805/DSITER-1] current_iter=1 written to state before first cycle_dispatch_stage call (write-before-dispatch; removing _cycle_state_write_iter_start leaves current_iter at init value)" \
    "1" "$_SPEC7W_CURRENT_ITER_AT_FIRST_DISPATCH"

# ── [#1805/DSCMBR-1] cycle member stages already complete in iter k are skipped ─
# On resume, within the interrupted iteration, cycle member stages already marked
# complete in persisted state are skipped; the first dispatched cycle member is
# the interrupted stage.
print_test_section "[#1805/DSCMBR-1] complete cycle members in interrupted iter skipped; interrupted member dispatched"

# Given — a run is being resumed; in the interrupted iteration (iter 2), member
#   stage "build" completed and member stage "test" was interrupted before
#   completing; persisted state records build as complete within iter 2.
#   _ZBUILD_RESUME_ACTIVE=true is exported.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Use zb_engine_loop_state to write cycle state: 2 rounds (iter 1 finished,
# iter 2 in_progress = current interrupted iter). After this call,
# cycle_iterations["build-test"].current_iter = 2.
zb_engine_loop_state "$STATE_FILE" "build-test" 2 5 "in_progress"

# Record that "build" completed in iter 2 before the interruption, and that
# "test" was interrupted (and therefore "aborted" — the value
# _cycle_state_write_member_atomic writes for an interrupted/aborted stage).
# Using "aborted" here (not "in_progress", which is never written by the real code)
# ensures the skip-guard check (`stage_statuses[$s] == "complete"`) is exercised on
# the production data shape: build=complete → skipped; test=aborted → dispatched.
# stage_statuses is what the cycle orchestrator checks to decide whether to skip a
# member on resume (ADR-006 §3.6 / DSCMBR-1).
# Use jq to merge this into the existing state; the cycle_iterations block
# written by zb_engine_loop_state is preserved (`.` merge keeps all other fields).
jq '.stage_statuses.build = "complete" | .stage_statuses.test = "aborted"' "$STATE_FILE" \
    > "${STATE_FILE}.cmbr1.tmp" && mv "${STATE_FILE}.cmbr1.tmp" "$STATE_FILE"

# Load the template: cycle-converges-iter2.yaml has build + test as cycle members,
# matching the state above.
load_template "$FIXT/cycle-converges-iter2.yaml"

# Track which cycle members are dispatched. cycle_dispatch_stage is what causes
# stage.start events in a unit-test context; not being called for "build" is
# functionally equivalent to no stage.start for build.
_CMBR1_BUILD_DISPATCHED=0
_CMBR1_TEST_DISPATCHED=0
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$stage" == "build" ]]; then
        _CMBR1_BUILD_DISPATCHED=1
    elif [[ "$stage" == "test" ]]; then
        _CMBR1_TEST_DISPATCHED=1
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

zb_stub_reports_tests test

# When — _ZBUILD_RESUME_ACTIVE=true is exported and the cycle orchestrator
#   dispatches members of iter k (iter 2). "build" is complete; "test" is pending.
set +e
export _ZBUILD_RESUME_ACTIVE=true
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_cmbr1_rc=$?
set -e

# Then — no stage.start event for "build" (already complete in iter k):
# cycle_dispatch_stage must NOT be called for "build" in iter 2.
# Before the change: orchestrator does not check member state on resume →
#   dispatches build regardless → _CMBR1_BUILD_DISPATCHED=1 → assert 0==1 → FAILS.
# After the change: orchestrator sees stage_statuses.build=complete in iter 2 →
#   skips build → _CMBR1_BUILD_DISPATCHED=0 → PASSES.
assert_eq \
    "[#1805/DSCMBR-1] no stage.start for 'build' in iter 2 (complete member skipped on resume within interrupted iter)" \
    "0" "$_CMBR1_BUILD_DISPATCHED"

# Then — stage.start is emitted for "test" (the interrupted member of iter k):
# cycle_dispatch_stage must be called for "test" in iter 2.
# Before the change: if orchestrator skips ALL members or aborts, test never
#   dispatches → _CMBR1_TEST_DISPATCHED=0 → assert 1==0 → FAILS.
# After the change: orchestrator skips build, dispatches test →
#   _CMBR1_TEST_DISPATCHED=1 → PASSES.
assert_eq \
    "[#1805/DSCMBR-1] stage.start emitted for 'test' in iter 2 (interrupted cycle member dispatched on resume)" \
    "1" "$_CMBR1_TEST_DISPATCHED"

# ── [#1805/DSCMBR-1] iter=1 scenario: most common interruption point ────────────
# Red-team finding: DSCMBR-1 skip guard must work for any interrupted iteration,
# including iter=1 (the most common first-failure point). The guard must NOT
# require _start_iter > 1; if it does, complete iter-1 members are re-dispatched.
print_test_section "[#1805/DSCMBR-1] iter=1 interrupted: build complete in iter=1 is skipped, test dispatched"

# Given — a run is being resumed; in the interrupted iteration (iter 1), member
#   stage "build" completed and member stage "test" was interrupted before
#   completing; persisted state records build as complete within iter 1.
#   _ZBUILD_RESUME_ACTIVE=true is exported.
: > "$ZBUILD_EVENTS_JSONL"
jq -n '{schema_version:1, stage_statuses:{}, updated_at:"seed"}' > "$STATE_FILE"

# Use zb_engine_loop_state to write cycle state: 1 round → current_iter=1
# (interrupted during iter 1; this is the most common interruption scenario).
# cycle_iterations["build-test"].current_iter = 1 (_start_iter = 1 on resume).
zb_engine_loop_state "$STATE_FILE" "build-test" 1 5 "in_progress"

# Record that "build" completed in iter 1 before the interruption.
# stage_statuses.build = "complete" is what the cycle orchestrator checks to
# decide whether to skip a member on resume (ADR-006 §3.6 / DSCMBR-1).
jq '.stage_statuses.build = "complete"' "$STATE_FILE" \
    > "${STATE_FILE}.cmbr1i1.tmp" && mv "${STATE_FILE}.cmbr1i1.tmp" "$STATE_FILE"

# Load the template: same cycle-converges-iter2.yaml, build + test as cycle members.
load_template "$FIXT/cycle-converges-iter2.yaml"

# Track which cycle members are dispatched. cycle_dispatch_stage causes stage.start
# events in a unit-test context; not being called for "build" is functionally
# equivalent to no stage.start for build.
_CMBR1I1_BUILD_DISPATCHED=0
_CMBR1I1_TEST_DISPATCHED=0
cycle_dispatch_stage() {
    local stage="$1" iter="$2"
    if [[ "$stage" == "build" ]]; then
        _CMBR1I1_BUILD_DISPATCHED=1
    elif [[ "$stage" == "test" ]]; then
        _CMBR1I1_TEST_DISPATCHED=1
    fi
    _CYCLE_DISPATCH_VERDICT="pass"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

zb_stub_reports_tests test

# When — _ZBUILD_RESUME_ACTIVE=true is exported and the cycle orchestrator
#   dispatches members of iter 1. "build" is complete; "test" is pending.
set +e
export _ZBUILD_RESUME_ACTIVE=true
cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"
_cmbr1i1_rc=$?
set -e

# Then — no stage.start event for "build" (already complete in iter 1).
# cycle_dispatch_stage must NOT be called for "build" in iter 1.
# Before the fix: DSCMBR-1 guard requires _start_iter > 1; for _start_iter=1 the
#   condition is false, _cid_resume_first_iter stays false → build IS dispatched →
#   _CMBR1I1_BUILD_DISPATCHED=1 → assert 0==1 → FAILS (exposes the code bug).
# After the fix: guard works for _start_iter=1 too → build is skipped →
#   _CMBR1I1_BUILD_DISPATCHED=0 → PASSES.
assert_eq \
    "[#1805/DSCMBR-1] no stage.start for 'build' in iter 1 (complete member skipped on resume within interrupted iter=1; DSCMBR-1 guard must work for _start_iter=1 not only _start_iter>1)" \
    "0" "$_CMBR1I1_BUILD_DISPATCHED"

# Then — stage.start is emitted for "test" (the interrupted member of iter 1).
# cycle_dispatch_stage must be called for "test" in iter 1.
# Before the fix: build is re-dispatched and test may also run, but the guard
#   failure means the skip invariant is violated.
# After the fix: build is skipped, test is dispatched →
#   _CMBR1I1_TEST_DISPATCHED=1 → PASSES.
assert_eq \
    "[#1805/DSCMBR-1] stage.start emitted for 'test' in iter 1 (interrupted cycle member dispatched; DSCMBR-1 applies to iter=1 not only iter>1)" \
    "1" "$_CMBR1I1_TEST_DISPATCHED"

# ── DSCYCL-1: test uses a fixture containing a cyclic stage ────────────────────
print_test_section "resume-loop-state test uses a fixture containing a cyclic stage"

# cycle-converges-iter2.yaml is loaded above via load_template and driven through
# cycle_orchestrator_run. Assert it contains type: cycle to formally pin the fixture
# contains a cyclic stage (as DSCYCL-1 requires).
# Then — the fixture used by this test file contains a stage of type: cycle
_s13_loop_fixt_content="$(cat "$FIXT/cycle-converges-iter2.yaml")"
assert_contains "[#1805/DSCYCL-1] cycle fixture used by resume-loop-state test has type: cycle" \
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
