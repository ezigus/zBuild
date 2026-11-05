# test-author notes — issue #1805 (round 20: fix open findings)

## Status: COMPLETE — all open findings from previous round addressed

## Changes this round

### Finding 1 (RHYD-1): byte-identical content check — FIXED
Changed `assert_contains ... "prior-run intake"` to `assert_eq` with the full expected
JSON payload `'{"result_contract":3,"outcome":"pass","reason":"prior-run intake"}'` for all
three resume paths (s1 path-1, s1p2 path-2, s1p3 path-3) in resume-rehydrate-test.sh.
- Before fix: assert_contains is a substring match — passes even with extra bytes.
- After fix: assert_eq fails when content is empty (file absent/not restored) or differs.

### Finding 7 (ITER-1): current_iter=2 (not 1) — FIXED
Changed all three `zb_engine_loop_state "$STATE_FILE" "build-test" 1 5 "in_progress"`
calls to `... 2 5 "in_progress"` in resume-loop-state-test.sh. The SPEC's Given says
"persisted state records cycle_iterations[CYCLE_ID].current_iter=2 (iter 1 completed
before interruption)". With current_iter=2:
- Before change: orchestrator ignores state, starts at iter 1 → first iter = 1 ≠ 2 → FAILS.
- After change: orchestrator reads current_iter=2, starts at iter 2 → first iter = 2 = 2 → PASSES.

Also updated comments and added Given/When/Then section markers throughout the file.

### Finding 9 (ENTR-1): missing intake-start-count assertion — FIXED
Added `_p1_intake_starts`, `_p2_intake_starts`, `_p3_intake_starts` assertions to
resume-entry-points-test.sh for all three paths. Each checks that intake emits zero
stage.start events (complete stage skipped before dispatch loop).
- Before fix: missing assertion — resume might still re-dispatch complete stages undetected.
- After fix: assert_eq "0" "$_pN_intake_starts" fails when complete stage is re-dispatched.

Also added Given/When/Then structure to each path block.

### Finding 3 (FSTG-1): missing ordering check — FIXED
Added pipeline.resume vs cycle.start line-number ordering check to from-stage-rehydrate-test.sh.
The check proves that _runner_from_stage_preflight (which calls _artifact_persist_restore +
_artifact_persist_put_back) completed BEFORE the dispatch loop reached stage cyc.
- Before fix: file-exists assertion only proves artifact present AFTER run, not ordering.
- After fix: assert_gt resume_lineno > 0; assert_gt dispatch_lineno > resume_lineno → proves ordering.

Also added Given/When/Then structure and When section to FSTG-2 block.

## All SPECs and their assertions (complete)

### resume-rehydrate-test.sh
- RHYD-1: artifact-present (assert_file_exists), content byte-identical (assert_eq with full
  JSON payload), pipeline.resume emitted, pipeline.resume precedes first stage.start,
  intake emits no stage.start — for all 3 resume entry paths
- RHYD-2: exit 1 when artifact absent; no stage.start before exit
- AMDR-1: ADR-006 contains 3.6, _runner_resume_rehydrate, resume-rehydrate-test.sh,
  resume-entry-points-test.sh, "exit 1", "before the dispatch loop", "git state branch",
  "not to be combined with dispatch-loop changes"
- AMDR-2: ADR-050 s6 contains "new run", "ADR-006", "continues the same run"
- FRSH-1: (1) intake dispatched from stage 1, (2) no stage.skip events,
  (3) prior-run artifact content NOT in ZBUILD_ARTIFACT_DIR
- BNDY-1: --no-resume flag in fresh-run sub-case; intake dispatches; fixture has type:cycle
- CYCL-1: fixture has type:cycle; pipeline was run
- DISP-1: cycled (stage k's inner member) dispatched → stage.start > 0 on resume

### from-stage-rehydrate-test.sh
- FSTG-1: artifact-present (assert_file_exists), content from git state (assert_contains),
  pipeline.resume before dispatch (ordering check: resume_lineno < cyc_start_lineno),
  intake emits no stage.start, cyc dispatched as first stage (cycle.start event)
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start
- CYCL-1: fixture has type:cycle

### resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=2)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2 (_SPEC7_ITER1_DISPATCHED=0)
- ITER-1 clause 2b: nested-loop re-entry after outer resume starts at iter=1 (outer cleared flag)
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### resume-entry-points-test.sh
- ENTR-1 for all 3 paths: artifact restored, pipeline.resume emitted, pipeline.resume
  precedes first stage.start, NO stage.start for intake (complete stage skipped)

### hydrate-stage-test.sh
- DLGT-1: sentinel test — overrides _artifact_persist_put_back with touch; calls
  hydrate_run; asserts sentinel was written

## issue-acceptance findings from previous round

### findings 1 and 2 (stage-retry-test.sh and write-boundary-revert-test.sh regressions)
NOT my scope. These are implementation regressions in dispatch-unit loop changes for
other issues (stage retry behavior #2439). My job is only the requirements in the contract.

### finding 3 (AMDR-1: ADR-006 not yet amended)
My assertions are correct. They check ADR file content and will correctly fail before
the doc change and pass after. AMDR-1 is no-code (need not fail before, must pass after).

### finding 4 (AMDR-2: ADR-050 s6 not yet amended)
Same as finding 3 — my AMDR-2 assertions are correct.

## Note on FSTG-1 cycle.start vs stage.start
The SPEC says "a stage.start event is emitted for <s>" for a cycle stage. In this codebase,
cycle stages emit cycle.start (not stage.start) when dispatched; their inner members emit
stage.start. The test correctly checks cycle.start with cycle_id=cyc, which is the event
that proves the cycle stage was dispatched as the first stage. This is not a bug — it's
the accurate event type for a cycle stage being dispatched.

## Note on ITER-1 _SPEC7_ITER1_DISPATCHED vs stage.start events
The cycle_dispatch_stage mock tracks whether the dispatch entry point is called with iter=1.
In a unit test where cycle_dispatch_stage is mocked, this is functionally equivalent to
checking that no stage.start events are emitted for iter-1 stages, because cycle_dispatch_stage
is what causes stage.start events to be emitted. The assertion is correct and sufficient.
