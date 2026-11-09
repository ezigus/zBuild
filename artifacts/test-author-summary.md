## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test finding 1: done — The `cycle.start > 0` assertions were replaced in the worktree with `stage.skip == 0` (DSFRSH-1 at lines 844–857, DSFRSH-2 at lines 980–994) in a prior round. The test stage finding came from running a stale scratch copy that predated those changes. The current worktree file has no `cycle.start > 0` assertions.
- answered: test-author finding 1: wrong — DSFRSH-1 is `[no-code]`; "its test must pass after this change; it need not fail before." `cycle.start > 0` for cyc produces 0 on current code (the cycle stage does not emit cycle.start before the new code lands), making `assert_gt` fail on current code — which directly violates the no-code property. The requirement "dispatches all stages from stage 1 with no stage skipped" is fully covered by: (a) `stage.start == 1` for intake (dispatch did not jump past stage 1), (b) `stage.skip == 0` (no skip guard fired), and (c) no prior-run artifact in ZBUILD_ARTIFACT_DIR (no rehydration invoked on a fresh run). These three assertions pass on current code and catch the bugs the SPEC guards against.
- answered: test-author finding 2: wrong — Same rationale as finding 1. DSFRSH-2 is `[no-code]`; asserting `cycle.start > 0` requires the new code to have run the cycle stage — a `[code]` behavior — so it fails on current code and violates the no-code property. The requirement is fully covered by `intake stage.start == 1` + `stage.skip == 0`.
- answered: lens-red-team-code finding 1: wrong — `stage.skip` is registered in `config/event-schema.json` precisely because the new code (this change) will emit it when skipping stages on resume. The assertion `stage.skip == 0` (a) passes on current code satisfying the no-code property, (b) directly tests the SPEC's Then clause "No stage.skip event is emitted for any stage," and (c) after the new code lands, catches any bug where the skip guard emits `stage.skip` on a fresh run when it should not. That no existing `.sh` file currently emits it is correct — the new code adds the emission; the assertion pre-validates the guard on the fresh-run side.
