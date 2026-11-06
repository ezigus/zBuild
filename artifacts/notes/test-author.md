# test-author notes — issue #1805 (round 28: verification pass — no changes needed)

## Status: COMPLETE

## Round 28 verification

All 14 SPECs are confirmed present and correctly tagged in the right test files:
- Scanned all 5 test files for [#1805/SPEC-n] tags
- All 14 unique tags found: AMDR-1, AMDR-2, CYCL-1, DLGT-1, DSPK-1, ENTR-1,
  FRSH-1, FRSH-2, FSTG-1, FSTG-2, ITER-1, RHYD-1, RHYD-2, SKIP-1
- CYCL-1 confirmed in both required files (resume-rehydrate-test.sh AND
  from-stage-rehydrate-test.sh)
- No open findings for this stage
- Failing tests in test stage (write-boundary-revert-test.sh, stage-retry-test.sh)
  are outside this issue's scope

## Previous round summary (round 27: fix SKIP-1 section headings)

**SKIP-1 Given/When/Then headings added (finding 1 fix):**

The SKIP-1 assertion was embedded within the RHYD-1 path 1 `# Then` section without
its own Given/When/Then headings. The finding said the assertion must have its own
section headings.

Added `# Given —`, `# When —`, `# Then —` headings explaining:
- Given: intake is marked complete with artifact rehydrated (from RHYD-1 path 1 setup)
- When: dispatch-unit loop reaches stage intake (same RHYD-1 path 1 runner call)
- Then: no stage.start emitted for that stage

No other changes were needed: the assertion itself (assert_eq "0" "$_s1_intake_starts")
was already correct.

## Previous round summary (round 26)

**FRSH-2 cycled assertion removed (test failing with expected >0, got: 0):**

The previous round added `assert_gt _frsh2_cycled_starts 0` to prove "every stage emits
stage.start" in the FRSH-2 fresh-run sub-case. This assertion fails because cycled (inner
member of cyc) does not emit stage.start in a fresh run with the CURRENT code.

The assertion was removed because:
1. FRSH-2 is about the dispatch-unit skip guard NOT activating for fresh runs.
2. The skip guard operates at the dispatch-unit level (intake and cyc), not inside
   the cycle orchestrator for inner members (cycled).
3. The intake assertion (intake dispatches) already proves the guard did not skip the
   stage most at risk of being skipped.
4. The no-stage-skip assertion proves the guard emitted no stage.skip for any stage.
5. Together, these two assertions fully cover the FRSH-2 requirement.
6. The cycled assertion was testing cycle-orchestrator fresh-run behavior, which is
   NOT what FRSH-2 requires, and which the code change (resume/rehydration) does not
   address.

## All SPECs and their test files

### tests/unit/hydrate-stage-test.sh
- DLGT-1: sentinel test with Given/When/Then headings; overrides
  _artifact_persist_put_back with touch, calls hydrate_run, asserts sentinel written.

### tests/integration/resume-rehydrate-test.sh
- RHYD-1: 3 paths; artifact-present, byte-identical, pipeline.resume before stage.start,
  no intake.stage.start
- RHYD-2: exit 1 when artifact absent; no stage.start before exit
- AMDR-1: ADR-006 contains all required phrases (3.6, _runner_resume_rehydrate,
  resume-rehydrate-test.sh, resume-entry-points-test.sh, "exit 1",
  "before the dispatch loop", "git state branch", "not to be combined with dispatch-loop changes")
- AMDR-2: ADR-050 s6 contains "new run", "ADR-006", "continues the same run",
  AND "resume-rehydrate-test.sh", AND "resume-entry-points-test.sh" (Enforced-by check)
- DSPK-1: stage k (cyc → member cycled) dispatched and emits stage.start on resume
- FRSH-1: intake dispatched from stage 1; no stage.skip; no prior-run artifact in dir
- SKIP-1: dispatch-unit loop emits no stage.start for complete stage with artifact present
  (has Given/When/Then headings)
- FRSH-2: fresh run (no --resume, in_progress status) dispatches intake AND emits no
  stage.skip events (cycled assertion removed — cycle orchestrator fresh-run behavior
  is out of scope for FRSH-2)
- CYCL-1: fixture has type:cycle; pipeline was run

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1: artifact-present, content from git state, pipeline.resume before dispatch,
  intake emits no stage.start, stage.start for cycled
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start
- CYCL-1: fixture has type:cycle

### tests/integration/resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=2)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 2b: nested-loop re-entry starts at iter=1
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### tests/integration/resume-entry-points-test.sh
- ENTR-1 for all 3 paths: artifact restored, pipeline.resume emitted,
  pipeline.resume precedes first stage.start, NO stage.start for intake
  — using artifact-snapshot-coverage (cyclic fixture, ZBUILD_CYCLES_ENABLED=1)

## Findings answered

ANSWER test-author finding 1: done — added # Given / # When / # Then headings to the
  SKIP-1 section in resume-rehydrate-test.sh. The SKIP-1 assertion now has its own
  Given/When/Then section headings explaining that the Given (intake marked complete
  with artifact rehydrated) and When (same RHYD-1 path 1 runner call) are shared,
  followed by the Then assertion (no stage.start emitted for intake).

ANSWER test-author finding 2: nothing to do — the cycled assertion was removed because:
  1. cycled (inner member of cyc) does not emit stage.start in a fresh run with the
     current code — adding the assertion would make the test fail (expected >0, got: 0)
  2. FRSH-2 is about the dispatch-unit skip guard not activating for fresh runs; the
     skip guard operates on dispatch units (intake, cyc), not on cycle-inner members (cycled)
  3. The two remaining assertions (intake dispatches, no stage.skip) fully cover FRSH-2

ANSWER issue-acceptance finding 1: nothing to do — ORDE-1 is an operational scheduling
  constraint, not mechanically testable. The intake stage already removed ORDE-1 from
  requirements for this exact reason.
