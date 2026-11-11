# test-author notes — issue #1805 (round 59)

## Status: ALL TESTS PASSING — CONFIRMED

All test files pass. 887 tests passed in the last test-stage run. No changes needed
in this round.

## All SPECs coverage

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSFSTG-3 ✓, DSFSTG-4 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓, DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓

### tests/unit/descriptive-id-readers-test.sh
- DSFSTG-1 ✓

## Findings answered

### lens-correctness-code finding 2
Wrong. `"aborted"` is the status the engine writes for an interrupted cycle member.
Confirmed in `core/pipeline/cycle-orchestrator.sh` base code: when a cycle member is
interrupted (SIGINT/SIGTERM path), `_cycle_state_write_member_atomic` writes
`"aborted"`. The DSCMBR-1 scenario specifically tests that the interrupted "test"
member is dispatched — if test were "complete", the skip guard would apply and it
would not be dispatched, which is the wrong behavior for an interrupted stage.
The "all complete" code path is a different scenario (all members complete means
the iteration is done and there's nothing to resume in it) and is not part of
DSCMBR-1's requirement.

### lens-correctness-design finding 1
Not mine. This is about the implementation in `core/pipeline/runner.sh` (how
`skip_until_stage` and `resume_mode` interact when `--from-stage` names a cycle).
The DSFSTG-3 test correctly asserts the observable behavior: stage.start (or
cycle.start) is emitted for stages after `<s>` and no stage.skip events are emitted.
That is what the code must satisfy regardless of internal mechanism. No change to
the test output is needed.

### acceptance-gate finding 1: DSFSTG-4 passes on before-code
DSFSTG-4 is classified `[done]` in the design — its test must pass on before-code
(the code from before this change already implements the guard). The acceptance gate
finding is not applicable to `[done]` requirements.

## Open findings

None outstanding.
