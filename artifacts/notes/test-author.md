# test-author notes — issue #1805 (round 38: verification pass)

## Status: COMPLETE (confirmed)

## Round 38 summary

Read all five test files and verified all prior work is on disk and correct.
No new "fix: test" findings from review_lenses require action.
All 16 SPECs confirmed present and tagged correctly.

## All SPECs coverage (all confirmed on disk)

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
- DSITER-1 ✓ (starts at iter=2 on resume; fresh/nested start at iter=1)
- DSCMBR-1 ✓ (iter=2 and iter=1 sub-cases: build skipped, test dispatched)

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓ (paths 1, 2, 3: artifact restored + pipeline.resume before stage.start)
- DSENTR-2 ✓ (path 4: auto-resume via latest symlink, ZBUILD_STATE_FILE/DIR unset)

## Answers to review_lenses findings (same as round 37)

ANSWER lens-red-team finding 3: done — added DSCMBR-1 iter=1 sub-case in resume-loop-state-test.sh;
  tests that build (complete in iter=1) is NOT dispatched and test IS dispatched on resume with
  _start_iter=1; will fail on current code (DSCMBR-1 _start_iter > 1 bug) and pass after fix.

ANSWER lens-correctness finding 4: nothing to do — the finding is incorrect about how
  `current_iter` is semantically written; `zb_engine_loop_state rounds=2` gives `current_iter=2`
  which correctly represents "interrupted during iter=2" (the test comment confirms this);
  changing to rounds=1 would assert _start_iter=2 from current_iter=1, but current code uses
  _start_iter=current_iter (not +1), so the test would fail on correct new code.

ANSWER lens-red-team finding 4: done — added `assert_eq "0" "$_s12_cycled_starts"` assertion
  to DSFRSH-1 sub-case in resume-rehydrate-test.sh; verifies cycle members do NOT emit stage.start
  on fresh runs; fails on current code (iter>0 bug causes unconditional stage.start for cycle
  members); passes after removing/guarding the iter>0 guard.

ANSWER lens-scope finding 3: nothing to do — the DSFSTG-1 assertion correctly tests the
  requirement that stage.start is emitted for <s>'s first cycle member; weakening to
  cycle.member.dispatch.start would allow the test to pass on incompletely-fixed code (where
  DSCMBR-1 _start_iter>1 bug persists); keeping stage.start correctly fails when code is
  incompletely fixed.

ANSWER lens-scope finding 4: nothing to do from test-author — cycle-member-dispatch-events-test.sh
  is not in my testfile list; cannot change it.
