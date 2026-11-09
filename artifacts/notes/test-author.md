# test-author notes — issue #1805 (round 52)

## Status: COMPLETE

All 16 SPECs confirmed on disk with correct tags. One finding addressed this round.

## Round 52 — fixed red-team finding 1

The red-team finding was correct: `stage.skip == 0` is vacuously true because
`stage.skip` is never emitted by any existing `.sh` file. Even after the new code
lands, if the skip guard suppresses a stage without emitting `stage.skip` (the
skip mechanism is "not emitting stage.start/cycle.start", not necessarily emitting
stage.skip), then `stage.skip == 0` does not catch the bug.

**Fix**: Added `cycle.start > 0` for the `cyc` cycle stage in BOTH DSFRSH-1 and
DSFRSH-2 sub-cases in `tests/integration/resume-rehydrate-test.sh`.

**Why this passes on current code** (no-code property preserved):
- The existing `core-pipeline-cycle-orchestrator-test.sh` asserts cycle.start is
  emitted, and that test passes. So cycle stages emit `cycle.start` in current code.
- In a fresh run with the artifact-snapshot-coverage fixture (intake leaf + cyc cycle),
  cyc dispatches normally → cycle.start emitted → count > 0 → assertion passes ✓

**Why this would catch bugs after the change**:
- If the skip guard erroneously activates for `cyc` in a fresh run (bug), it would
  suppress `cyc`'s dispatch without emitting `cycle.start` → count == 0 → fails ✓
- The existing `stage.skip == 0` would NOT catch this (cyc would just be silently
  not dispatched), but `cycle.start > 0` DOES catch it.

**Previous notes were wrong**: Earlier rounds claimed `cycle.start > 0` would be 0
on current code. That was incorrect — `core-pipeline-cycle-orchestrator-test.sh`
confirms cycle.start IS emitted on current code for cycle stages.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓ (stage.start=1 + stage.skip=0 + cycle.start>0 for cyc + no prior artifact + cycled stage.start=0)
- DSSKIP-1 ✓, DSFRSH-2 ✓ (stage.start=1 + stage.skip=0 + cycle.start>0 for cyc), DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
