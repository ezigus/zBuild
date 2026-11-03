# test-author notes — issue #1805 (round 15: verify completion)

## Status: COMPLETE — no changes needed this round

## Previous work confirmed correct

All 5 test files were read in full this round. Every SPEC has its assertion:

### resume-rehydrate-test.sh
- RHYD-1: artifact-present assertions (file exists + content from git state branch),
  dispatch-loop ran (at least 1 stage.start), pipeline.resume before first stage.start,
  intake emits no stage.start — for all 3 paths (--resume, auto-resume, zbuild pipeline resume)
- RHYD-2: exit 1 when artifact absent from disk AND state branch; no stage.start before exit
- AMDR-1: ADR-006 contains 3.6, _runner_resume_rehydrate, resume-rehydrate-test.sh,
  resume-entry-points-test.sh, "exit 1", "before the dispatch loop", "git state branch",
  "not to be combined with dispatch-loop changes"
- AMDR-2: ADR-050 §6 contains "new run", "ADR-006", "continues the same run"
- BNDY-1: --no-resume flag in the fresh-run sub-case; intake dispatches in fresh run
  (pinning the new-run side of ADR-006/ADR-050 §6 boundary); fixture has type: cycle
- CYCL-1: fixture (artifact-snapshot-coverage) has type: cycle; pipeline was run

### from-stage-rehydrate-test.sh
- FSTG-1: artifact-present + content from git state branch; intake emits no stage.start;
  cyc dispatched as first stage (cycle.start with cycle_id=cyc)
- FSTG-2: exit 1 when prior stage has no restorable artifact; stderr contains
  "has no restorable primary artifact"; no stage.start before exit
- CYCL-1: fixture (artifact-snapshot-coverage) has type: cycle

### resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=1)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### resume-entry-points-test.sh
- ENTR-1 for all 3 paths:
  - artifact restored from state branch (file exists)
  - pipeline.resume event emitted (resume_lineno > 0)
  - pipeline.resume precedes first stage.start (rehydration before dispatch loop)

### hydrate-stage-test.sh
- DLGT-1: sentinel test — overrides _artifact_persist_put_back with touch; calls
  hydrate_run; asserts sentinel was written → fails when plugin.sh is reverted to
  inline _hydrate_put_back

## Answers to previous open findings

### test-author finding 1: ITER-1 nested-loop guard clause
ANSWER: nothing to do — resume-loop-state-test.sh lines 105-144 already have
the guard sub-test with a properly tagged [#1805/ITER-1] assertion:
"[#1805/ITER-1] without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1
(guard prevents iter-skip)". This was added in a prior round.

## issue-acceptance findings — not in test-author scope

- issue-acceptance finding 1: stage-retry regressions (stage-retry-test.sh,
  write-boundary-revert-test.sh) — these are in OTHER test files unrelated to
  issue #1805 test-authoring; they reflect code regressions in the implementation
  (dispatch loop changes affecting fresh-run retry paths). Outside test-author scope.

- issue-acceptance finding 2: same files, same diagnosis. Outside scope.

- issue-acceptance finding 3: ADR-006 not visible in diff — our AMDR-1 tests
  check the doc content (8 specific phrases). Will pass when the implementation
  team amends the doc. Test is correct.

- issue-acceptance finding 4: ADR-050 not visible in diff — our AMDR-2 tests
  check the §6 content (3 specific phrases). Will pass when the doc is amended.
  Test is correct.
