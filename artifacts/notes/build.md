# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 23 — All tests pass; all findings answered; no code changes needed

## Verification of previous iteration's fixes (all confirmed in current worktree)

All 5 acceptance tests pass (887/887 total):
- resume-rehydrate-test.sh
- from-stage-rehydrate-test.sh
- resume-loop-state-test.sh
- resume-entry-points-test.sh
- hydrate-stage-test.sh

### Correctness finding 1 (cycle:* skip guard dead code)
WRONG — runner.sh:3792-3793 adds `_update_stage_status "$state_file" "$_cyc_id" "complete"` 
inside `if [[ "$_cyc_outcome" == "converged" ]]`, so cycles ARE written to stage_statuses when
they converge. The skip guard at lines 3591-3597 can find the status. Not dead code.

### Correctness finding 2 (_ZBUILD_FROM_STAGE_EMIT_START sets _is_resume=true)
WRONG — cycle-orchestrator.sh:2462-2465 uses a SEPARATE `_from_stage_cycle_start` local 
variable. `_is_resume` is set only when `_ZBUILD_RESUME_ACTIVE=true`. They are independent.

### Correctness finding 3 (skip guard reads flat stage_statuses without iteration reset)
WRONG — cycle-orchestrator.sh:1406-1422 has a pre-scan: when `_resume_first_iter=true`, it
counts non-complete members; if ALL are complete (interrupted before any dispatch of iter N),
sets `_resume_first_iter=false` and `_from_stage_start=true`. All-complete edge case handled.

### Security finding 1 (reads through unresolved symlink)
WRONG — runner.sh:1861-1863 reads from `$_ls_issue_resolved/pipeline-state.json` (the
`readlink -f`-resolved path), not through the symlink. TOCTOU race is eliminated.

### sre finding 4 (no machine-readable event in _runner_from_stage_preflight)
WRONG — runner.sh:1786-1789 emits `eb_emit_event "stage.verdict.stale_artifact"` with
`stage`, `from_stage`, `path`, and `run_id` fields before returning 1.

### sre findings 1-3 (observability of infrastructure failures)
WRONG — these concern machine-readable events for jq/write failures, which:
- sre-1: jq blob update failure at cycle-orchestrator.sh:1483: the && pattern is intentional;
  blob unchanged (safe), cycle.iteration.reused event already emitted; cycle exit predicates
  may evaluate against stale data only on jq infrastructure failure (not normal operation);
  no stated requirement covers this.
- sre-2: _cycle_state_write_iter_start failure: existing warn-and-continue pattern; adding
  machine-readable events for infrastructure write failures requires event-schema changes
  outside this issue's scope.
- sre-3: _artifact_persist_put_back failure: returns 0 with warn; still-absent artifacts
  are caught by the dispatch-loop fail-closed stale-artifact check at runner.sh:3950 which
  DOES emit stage.verdict.stale_artifact; root-cause observability is a sre-quality note,
  non-blocking per category, outside this issue's acceptance criteria.

### red-team finding 1 (stage.skip assertions vacuously true)
NOT MINE — in read-only acceptance test file tests/integration/resume-rehydrate-test.sh.

### scope finding 1 (SPEC-3b doesn't exercise skip_restore=false)
NOT MINE — in read-only acceptance test file tests/integration/from-stage-rehydrate-test.sh.

### scope finding 2 (ADR reference §3.5 instead of §3.6)
NOT MINE — in read-only acceptance test file tests/integration/from-stage-rehydrate-test.sh.
Does not block.

### performance finding 1 (resume_mode never cleared)
WRONG — non-blocking; clearing resume_mode mid-loop requires threading "passed interrupted
stage" signal through the dispatch loop; subsequent stages after the interrupted one cannot
be `complete` in a correctly-interrupted run, so the guard short-circuits after one jq
lookup per remaining stage; this is a performance trade-off, not a correctness gap.
