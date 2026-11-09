# test-author notes — issue #1805 (round 51)

## Status: COMPLETE

All 16 SPECs confirmed on disk with correct tags. All findings answered in this round.

## Round 51 — no file changes needed

The worktree files are already correct. The test stage's failing assertions came from a
stale scratch copy (`zbuild-test-stage.sQ3HtM`) that still had `cycle.start > 0`
assertions written in an earlier round. The current worktree (`tests/integration/
resume-rehydrate-test.sh`) has the correct `stage.skip == 0` assertions at:
- Lines 844-857 (DSFRSH-1 — `emits no stage.skip events`)
- Lines 980-994 (DSFRSH-2 — `emits no stage.skip events`)

The `cycle.start > 0` assertions are GONE from the worktree.

## Why test-author finding 1 and 2 are WRONG (not just not-done)

DSFRSH-1 and DSFRSH-2 are both `[no-code]` requirements:
"its test must pass after this change; it need not fail before."

`cycle.start > 0` would be 0 on current code (the cycle stage does not emit cycle.start
in a fresh run with the current implementation). That makes `assert_gt cycle.start 0`
fail on current code → violates the no-code property. The no-code property REQUIRES the
test to pass on current code.

The correct assertions for these no-code specs:
- `intake stage.start == 1` (dispatch started from stage 1; not skipped over)
- `stage.skip == 0` (no skip guard fired, which the new code adds)
- `no prior-run artifact in ZBUILD_ARTIFACT_DIR` (no rehydration on fresh run — DSFRSH-1)
- `cycled stage.start == 0` (cycle members must not get stage.start on fresh runs — DSFRSH-1)

These cover the SPEC's observable behavior completely, pass on current code, and will
catch bugs in the new code that emit skip events or rehydrate on fresh runs.

## Why lens-red-team-code finding 1 is WRONG

The lens says `stage.skip == 0` is vacuously true because stage.skip is never emitted
by any existing `.sh` file. But:
1. `stage.skip` IS registered in `config/event-schema.json` — that is because the NEW
   code (this change) will emit it when skipping stages on resume.
2. The assertion `stage.skip == 0` correctly passes on current code (no-code ✓).
3. After the new code lands, if the skip guard has a bug that emits `stage.skip` on fresh
   runs, `stage.skip == 0` FAILS → the test catches the bug.
4. The assertion tests exactly what the SPEC says: "And: No stage.skip event is emitted
   for any stage."

## All SPECs coverage (unchanged from round 50)

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓ (stage.start=1 + stage.skip=0 + no prior artifact + cycled stage.start=0)
- DSSKIP-1 ✓, DSFRSH-2 ✓ (stage.start=1 + stage.skip=0), DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓ (S3: cycle-stage+--resume, S5: cycle-stage no-resume, S6: leaf-stage)
- DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
