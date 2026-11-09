# test-author notes — issue #1805 (round 53)

## Status: COMPLETE

All 16 SPECs confirmed on disk with correct tags.

## Round 53 — fixed test finding 1

**Problem**: `cycle.start > 0` assertions in DSFRSH-1 and DSFRSH-2 fail on current
code (pre-change) with `ZBUILD_CYCLES_ENABLED=1` set explicitly.

**Root cause**: With `ZBUILD_CYCLES_ENABLED=1` set explicitly, the runner uses a NEW
dispatch code path introduced by this PR. That path is not fully implemented on
pre-change code, so cycle stages don't dispatch (`cycle.start == 0`). Without
explicit `ZBUILD_CYCLES_ENABLED=1`, cycles auto-detect (the template declares them),
and the existing auto-detect path dispatches cycles correctly (`cycle.start > 0`).

**Evidence**: `artifact-snapshot-runner-test.sh` runs the same `artifact-snapshot-
coverage` fixture WITHOUT `ZBUILD_CYCLES_ENABLED=1` and passes `SPEC-2: cycle member
snapshotted`. This confirms cycles work via auto-detect on current code.

**Fix**: Removed `ZBUILD_CYCLES_ENABLED=1` from the DSFRSH-1 and DSFRSH-2 runner
invocations in `tests/integration/resume-rehydrate-test.sh`:
- DSFRSH-1 (--no-resume sub-case, ~line 804): removed `ZBUILD_CYCLES_ENABLED=1 \`
- DSFRSH-2 (no --resume sub-case, ~line 964): removed `ZBUILD_CYCLES_ENABLED=1 \`

**Why this is semantically correct**:
- The skip guard (new code) is conditional on `resume_mode`, NOT `ZBUILD_CYCLES_ENABLED`.
  So testing with auto-detect cycles is just as valid for the guard assertion.
- Without explicit `ZBUILD_CYCLES_ENABLED=1`: cycles auto-detect via template, the
  dispatch-unit loop runs (where the skip guard lives), and `cycle.start > 0` on
  current code ✓
- After the change: skip guard is `resume_mode`-conditional, fresh run → `resume_mode=
  false` → guard doesn't fire → `cycle.start > 0` ✓
- If skip guard has a bug and fires on fresh runs: `cycle.start == 0` → test fails ✓

**Why round 52 notes were wrong**: The notes claimed `cycle.start > 0` passes on
current code with `ZBUILD_CYCLES_ENABLED=1`. That was incorrect. The issue is that
with `ZBUILD_CYCLES_ENABLED=1`, the new dispatch path is activated but incomplete
pre-change.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓ (stage.start=1 + stage.skip=0 + cycle.start>0 for cyc [auto-detect] + no prior artifact + cycled stage.start=0)
- DSSKIP-1 ✓, DSFRSH-2 ✓ (stage.start=1 + stage.skip=0 + cycle.start>0 for cyc [auto-detect]), DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
