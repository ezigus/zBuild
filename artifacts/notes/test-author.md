# test-author notes — issue #1805 (round 41: fix open findings from test-author stage)

## Status: COMPLETE

## Round 41 summary

Fixed 2 open findings from the previous test-author run (verdict: unusable):

### test-author finding 1
`_ZBUILD_RESUME_ACTIVE=true` was placed under the `# When` heading in the DSITER-1
first sub-case, but the SPEC lists it as a Given precondition.

Fix: moved `export _ZBUILD_RESUME_ACTIVE=true` out of the `# When` block and placed it
under a new `# Given` comment immediately before the `# When` block.
File: tests/integration/resume-loop-state-test.sh

### test-author finding 2
DSCMBR-1 iter-2 sub-case set only `stage_statuses.build = "complete"` but did not
set `stage_statuses.test = "in_progress"`. The Given says "persisted state records
build as complete and test as in-progress within iter k".

Fix: changed the jq call in the DSCMBR-1 iter-2 sub-case to also set
`.stage_statuses.test = "in_progress"` alongside `.stage_statuses.build = "complete"`.
File: tests/integration/resume-loop-state-test.sh

## All SPECs coverage (all confirmed on disk with correct tags)

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓ (lines 235–266: sentinel test for _artifact_persist_put_back delegation)

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓ (paths 1, 2, 3: artifact restored byte-identical + no intake stage.start)
- DSRHYD-2 ✓ (exit 1 when artifact absent from both disk and state branch)
- DSAMDR-1 ✓ (ADR-006 step 3.6 presence check)
- DSAMDR-2 ✓ (ADR-050 §6 boundary note check)
- DSDSPK-1 ✓ (cyc → cycled stage.start on resume)
- DSFRSH-1 ✓ (--no-resume dispatches all from stage 1; no cycled stage.start on fresh run)
- DSSKIP-1 ✓ (dispatch-unit loop emits no stage.start for complete+rehydrated stage)
- DSFRSH-2 ✓ (fresh run with in_progress status dispatches intake, no stage.skip)
- DSCYCL-1 ✓ (fixture contains type: cycle, tagged [#1805/DSCYCL-1])

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓ (intake restored, cycled stage.start, no intake stage.start)
- DSFSTG-2 ✓ (exit 1 + "has no restorable primary artifact" on stderr)
- DSCYCL-1 ✓ (fixture contains type: cycle, tagged [#1805/DSCYCL-1])

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓ (starts at iter=2 on resume; fresh/nested start at iter=1; _ZBUILD_RESUME_ACTIVE=true in Given)
- DSCMBR-1 ✓ (iter=2 sub-case: build skipped, test dispatched; stage_statuses.test=in_progress; iter=1 sub-case too)
- DSCYCL-1 ✓ (fixture contains type: cycle, tagged [#1805/DSCYCL-1]; # Then heading present)

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓ (paths 1, 2, 3: artifact restored + pipeline.resume before stage.start)
- DSENTR-2 ✓ (path 4: auto-resume via latest symlink, ZBUILD_STATE_FILE/DIR unset via env -u)
- DSCYCL-1 ✓ (fixture contains type: cycle, tagged [#1805/DSCYCL-1]; # Then heading present)

## Answers to findings

ANSWER test-author finding 1: done — moved `export _ZBUILD_RESUME_ACTIVE=true` from
  the `# When` block to a new `# Given` comment block immediately before the When
  section in the DSITER-1 first sub-case in resume-loop-state-test.sh.

ANSWER test-author finding 2: done — updated the DSCMBR-1 iter-2 jq call to also set
  `.stage_statuses.test = "in_progress"` alongside `.stage_statuses.build = "complete"`,
  matching the SPEC Given ("persisted state records build as complete and test as
  in-progress within iter k").

ANSWER lens-correctness-code finding 2: nothing to do — the SPEC (DSITER-1 Given)
  explicitly states "persisted state records cycle_iterations[CYCLE_ID].current_iter=2
  (iter 1 completed before interruption)"; the test fixture follows the SPEC using
  `zb_engine_loop_state rounds=2` to produce `current_iter=2`; this correctly fails on
  old code (ignores current_iter, starts at 1 → assert_eq 2 1 → FAIL) and passes on
  new code (reads current_iter=2, starts at 2 → PASS); if the code writer uses a
  different formula (finding 1, fix: code), that is a code issue.

ANSWER lens-correctness-code finding 3: nothing to do — same reasoning as finding 2;
  the DSCMBR-1 scenario uses `current_iter=2` per the SPEC ("iter 1 completed, iter 2
  in-progress"); the test correctly validates member-skip in the interrupted iteration.

ANSWER lens-scope-code finding 1: nothing to do — the DSENTR-2 sub-case (path 4) in
  resume-entry-points-test.sh already uses `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`;
  the latest-symlink auto-resume branch IS exercised by path 4; paths 1-3 test other
  entry paths and correctly set ZBUILD_STATE_FILE.

## Changes made this round

1. tests/integration/resume-loop-state-test.sh:
   - Moved `export _ZBUILD_RESUME_ACTIVE=true` from `# When` block to new `# Given` block
     in DSITER-1 first sub-case
   - Added `.stage_statuses.test = "in_progress"` to the DSCMBR-1 iter-2 jq call
