# test-author notes — issue #1805 (round 25: fix open findings 1 and 2)

## Status: COMPLETE — both open findings addressed

## Changes made this round

### tests/integration/resume-rehydrate-test.sh (only file changed)

**AMDR-2 fix (test-author finding 1):**
Added two assert_contains after the existing "continues the same run" assertion in the
AMDR-2 section (after line 604):
- `assert_contains "[#1805/AMDR-2] ADR-050 §6 Enforced-by section cites resume-rehydrate-test.sh (FRSH-2 for new-run side)" "$_adr050_s6" "resume-rehydrate-test.sh"`
- `assert_contains "[#1805/AMDR-2] ADR-050 §6 Enforced-by section cites resume-entry-points-test.sh (ENTR-1 for resume side)" "$_adr050_s6" "resume-entry-points-test.sh"`
These two assertions fail when §6 has the boundary prose but lacks the Enforced-by update.
Both are no-code requirements (need not fail before the change; must pass after).

**FRSH-2 fix (test-author finding 2):**
Added assert_gt for `_frsh2_cycled_starts > 0` after the "no stage.skip" assertion in
the FRSH-2 section. This asserts that the cycle member `cycled` (inner member of `cyc`)
also emits stage.start on a fresh run, proving every stage dispatches (not just `intake`).
Without this, a run where only `intake` dispatched but `cycled` was silently skipped would
still pass the intake-only assertion. This is a no-code requirement (need not fail before;
must pass after).

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
  AND "resume-rehydrate-test.sh", AND "resume-entry-points-test.sh" (Enforced-by check added)
- DSPK-1: stage k (cyc → member cycled) dispatched and emits stage.start on resume
- FRSH-1: intake dispatched from stage 1; no stage.skip; no prior-run artifact in dir
- SKIP-1: dispatch-unit loop emits no stage.start for complete stage with artifact present
- FRSH-2: fresh run dispatches intake AND cycled (every stage); no stage.skip
- CYCL-1: fixture has type:cycle; pipeline was run

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1: artifact-present, content from git state, pipeline.resume before dispatch,
  intake emits no stage.start, stage.start for cycled
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start
- CYCL-1: fixture has type:cycle

### tests/integration/resume-loop-state-test.sh (unchanged)
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=2)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 2b: nested-loop re-entry starts at iter=1
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### tests/integration/resume-entry-points-test.sh (unchanged from last round)
- ENTR-1 for all 3 paths: artifact restored, pipeline.resume emitted,
  pipeline.resume precedes first stage.start, NO stage.start for intake
  — using artifact-snapshot-coverage (cyclic fixture, ZBUILD_CYCLES_ENABLED=1)
  so the assertions exercise the dispatch-unit loop, not the legacy linear loop.

## Findings answered

ANSWER test-author finding 1: done — added two assert_contains in the AMDR-2 section of
  resume-rehydrate-test.sh asserting that §6's Enforced-by section cites
  resume-rehydrate-test.sh and resume-entry-points-test.sh by name. A §6 that adds the
  boundary prose but omits the Enforced-by update would still pass the original three
  assertions but fail these two.

ANSWER test-author finding 2: done — added assert_gt for _frsh2_cycled_starts > 0 in the
  FRSH-2 section of resume-rehydrate-test.sh. This asserts that cycled (inner member of
  the cyc cycle stage) also emits stage.start on a fresh run, proving every stage dispatches
  not just intake. The intake-only assertion was insufficient; this new assertion covers
  all stages in the fixture.

ANSWER issue-acceptance finding 1: done — changed all three entry-path sub-tests in
  resume-entry-points-test.sh from runner-state-dir-minimal/ZBUILD_CYCLES_ENABLED=0
  to artifact-snapshot-coverage/ZBUILD_CYCLES_ENABLED=1; stage_statuses changed from
  {intake: complete, build: pending} to {intake: complete, cyc: pending} in all three
  state files.

ANSWER issue-acceptance finding 2: done — added [#1805/SKIP-1] assertion (after RHYD-1
  path-1 intake check, reusing $_s1_intake_starts) and [#1805/FRSH-2] sub-case (fresh
  run with prior state branch artifacts, status=in_progress, no --resume; asserts intake
  dispatches, cycled dispatches, and no stage.skip) to resume-rehydrate-test.sh.

ANSWER issue-acceptance finding 3: nothing to do — ORDE-1 is an operational scheduling
  constraint (do not run this in parallel with issue #1714). It cannot be mechanically
  enforced by a test; it requires CI or issue-tracking evidence. That is outside test-author
  scope. No test file can prove two issues were not in flight concurrently.
