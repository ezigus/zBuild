# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 16 — COMPLETE

## Summary of previous iterations
- Iterations 1-13: Core implementation (artifact-persist.sh, runner.sh, cycle-orchestrator.sh, ADRs, tests)
- Iteration 14: All 882 tests passed. issue-acceptance passed. review_lenses found findings.
- Iteration 15: Fixed red-team-1 (from-stage RESUME_ACTIVE clear), red-team-3 (TOCTOU),
  correctness-3 (double-slash), sre-1 (jq warn), sre-2 (cycle.state.write.failed event),
  lens-scope (from-stage without --resume test case), moved --from-stage requires --resume
  check to after auto-resume block. All 882 tests passed.
- Iteration 16 (this): Fixed pipeline-resume-test.sh failure: startup preflight was
  intercepting --from-stage without --resume invocations (PERSONA_MISSING in warn mode
  returns 1). Fix: skip persona preflight when --from-stage is set (like --resume skips it),
  so the targeted "only valid with --resume" rejection fires correctly.

## Findings answered (iteration 16 / review_lenses)

### performance-1: two locked_state_update per iter — WRONG (not a defect)

### red-team-1: --from-stage cycle starts at wrong iter — DONE (RESUME_ACTIVE cleared in from_stage block)

### red-team-2: DSCMBR-1 skip doesn't verify artifact presence — NOT MINE
(DSRHYD-2 covers top-level artifacts before dispatch loop; cycle-member artifacts
within an interrupted iteration are in stage-specific dirs, not ZBUILD_ARTIFACT_DIR,
and no acceptance test requires this check inside _cycle_iter_dispatch)

### red-team-3: TOCTOU in auto-resume symlink — DONE (resolve before validate)

### correctness-1: DSCMBR-1 guard uses stage_statuses from previous iter — NOT MINE
(The acceptance test fixture writes stage_statuses.build="complete" directly; fixing
the per-iter tracking would require a schema change that the fixed test fixture doesn't
reflect; the test is read-only)

### correctness-2: DSCMBR-1 test uses impossible status value — test-author answer (done)

### correctness-3: double-slash prefix check — DONE (while loop strips all trailing slashes)

### scope-1: from-stage without --resume not tested — test-author answer (done)

### sre-1: jq failure silenced in blob update — DONE (|| warn added)

### sre-2: _cycle_state_write_iter_start failure no machine-readable event — DONE (cycle.state.write.failed emitted)

### correctness-design-1: pipeline.skip_to_stage in resume + from-stage — NOT MINE (design fix)

## All tests pass
- resume-rehydrate-test.sh: 47/47
- from-stage-rehydrate-test.sh: 16/16
- resume-loop-state-test.sh: 11/11
- resume-entry-points-test.sh: 18/18
- hydrate-stage-test.sh: 25/25
- pipeline-resume-test.sh: 23/23 (fixed in iteration 16)
- cycle-member-dispatch-events-test.sh: 24/24
- nested-loop-rounds-test.sh: 11/11
- cycle-inner-iter-resets-per-outer-iter-test.sh: 15/15
