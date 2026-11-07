# test-author notes — issue #1805 (round 37: fix review_lenses test findings)

## Status: COMPLETE

## Round summary

review_lenses stage found code bugs and test gaps. My job: fix the test gaps.

### "fix: test" findings to address

1. **lens-red-team finding 3** (fix: test): Add CMBR-1 sub-case for iter=1
   - resume-loop-state-test.sh
   - Insert new sub-case with rounds=1 → `current_iter=1`, `stage_statuses.build=complete`
   - Asserts build NOT dispatched, test dispatched
   - Fails on current code (`_start_iter > 1` bug); passes after code fix

2. **lens-correctness finding 4** (fix: test): NOTHING TO DO
   - Finding says `current_iter=2` from rounds=2 is wrong for "interrupted during iter=2"
   - But all 882 tests pass with rounds=2 and asserting `_start_iter=2 = current_iter=2`
   - The comment says "iter 2 in_progress = current interrupted iter" with `current_iter=2`
   - `zb_engine_loop_state rounds=N` gives `current_iter=N`; test correctly represents scenario
   - Changing to rounds=1 would assert `_start_iter=2` from `current_iter=1`, but code
     uses `_start_iter=current_iter` (not +1), so would fail on correct new code
   - Conclusion: finding is wrong about semantics. Leave unchanged.

3. **lens-scope finding 3** (fix: test): NOTHING TO DO
   - Assertion at from-stage-rehydrate-test.sh:185 checks `stage.start > 0` for cycled
   - FSTG-1 requirement says "stage.start is emitted for <s>'s first cycle member"
   - Weakening to `cycle.member.dispatch.start` would let the test pass on incompletely-fixed code
   - If code fix removes `iter > 0` without fixing CMBR-1 for `_start_iter=1`, assertion
     correctly fails (exposing incomplete fix). Leave unchanged.

4. **lens-red-team finding 4** (fix: test): Add cycled stage.start=0 to FRSH-1 sub-case
   - resume-rehydrate-test.sh
   - Add assertion that cycled emits 0 stage.starts on fresh run
   - Design: stage.start for cycle members only via CMBR-1 resume path; not on fresh runs
   - Fails on current code (`iter > 0` bug emits stage.start unconditionally); passes after fix

5. **lens-scope finding 4** (fix: test for cycle-member-dispatch-events-test.sh): OUT OF SCOPE
   - That file is not in my testfile list. Cannot change it.

### "fix: code" findings: OUT OF SCOPE for test-author
- lens-security findings 1, 2
- lens-performance finding 1 (iter > 0 guard always true — code fix)
- lens-red-team findings 1, 2 (CMBR-1 _start_iter > 1 bug — code fix)
- lens-correctness findings 1, 2, 3 (iter > 0 / CMBR-1 bugs — code fix)
- lens-scope findings 1, 2 (iter > 0 — code fix)
- lens-sre findings 1-5 (logging gaps — code fix)

## Changes made this round

1. resume-loop-state-test.sh: added CMBR-1 iter=1 sub-case (before CYCL-1 section)
2. resume-rehydrate-test.sh: added cycled stage.start=0 assertion to FRSH-1 sub-case

## Answers to findings

ANSWER lens-red-team finding 3: done — added CMBR-1 iter=1 sub-case in resume-loop-state-test.sh;
  tests that build (complete in iter=1) is NOT dispatched and test IS dispatched on resume with
  _start_iter=1; will fail on current code (CMBR-1 _start_iter > 1 bug) and pass after fix.

ANSWER lens-correctness finding 4: nothing to do — the finding is incorrect about how
  `current_iter` is semantically written; `zb_engine_loop_state rounds=2` gives `current_iter=2`
  which correctly represents "interrupted during iter=2" (the test comment confirms this);
  changing to rounds=1 would assert _start_iter=2 from current_iter=1, but current code uses
  _start_iter=current_iter (not +1), so the test would fail on correct new code.

ANSWER lens-red-team finding 4: done — added `assert_eq "0" "$_s12_cycled_starts"` assertion
  to FRSH-1 sub-case in resume-rehydrate-test.sh; verifies cycle members do NOT emit stage.start
  on fresh runs; fails on current code (iter>0 bug causes unconditional stage.start for cycle
  members); passes after removing/guarding the iter>0 guard.

ANSWER lens-scope finding 3: nothing to do — the FSTG-1 assertion correctly tests the
  requirement that stage.start is emitted for <s>'s first cycle member; weakening to
  cycle.member.dispatch.start would allow the test to pass on incompletely-fixed code (where
  CMBR-1 _start_iter>1 bug persists); keeping stage.start correctly fails when code is
  incompletely fixed.

ANSWER lens-scope finding 4: nothing to do from test-author — cycle-member-dispatch-events-test.sh
  is not in my testfile list; cannot change it.

## All SPECs coverage (unchanged from previous round)

### tests/unit/hydrate-stage-test.sh
- DLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- RHYD-1 ✓
- RHYD-2 ✓
- AMDR-1 ✓
- AMDR-2 ✓
- DSPK-1 ✓
- FRSH-1 ✓ (added cycle-member stage.start=0 assertion for GUAR-1 cycle-member side)
- SKIP-1 ✓
- FRSH-2 ✓
- CYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1 ✓
- FSTG-2 ✓
- CYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- ITER-1 ✓
- CMBR-1 ✓ (added iter=1 sub-case for missing first-failure scenario)

### tests/integration/resume-entry-points-test.sh
- ENTR-1 ✓
- ENTR-2 ✓
