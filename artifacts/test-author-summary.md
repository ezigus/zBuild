## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/integration/cycle-member-dispatch-events-test.sh — FRSH-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done** — Added `assert_gt "[#1805/DSPK-1] cycle.start emitted for stage k (cyc) on resume..."` after the existing DSPK-1 assertion. The DSPK-1 requirement says "when k is a cycle stage, a cycle.start event is emitted for k AND stage.start is emitted for k's first cycle member". The cycle member's `stage.start` was already asserted; the `cycle.start` for the stage itself was missing. The new assertion: before the code change, runner aborts before dispatching cyc → no cycle.start → count=0 → FAILS; after the change, dispatch loop reaches cyc → cycle.start emitted → count=1 → PASSES.
- answered: test-author finding 2: done** — Added `assert_gt "[#1805/FRSH-2] cycle stage cyc dispatched on fresh run (cycle.start emitted; dispatch-unit skip guard conditional on resume_mode — does not silently skip cyc)"` after the existing FRSH-2 assertions. The two prior assertions (intake dispatches, no stage.skip) would not detect a skip guard that silently skips cyc without emitting stage.skip. The new `cycle.start` count > 0 assertion catches this: if a buggy skip guard suppresses cyc → no cycle.start → count=0 → FAILS. FRSH-2 is [no-code] so it need not fail on old code; it must pass after the change. The FRSH-2 runner call already sets `ZBUILD_CYCLES_ENABLED=1` so cyc will be dispatched and `cycle.start` emitted on a fresh run.
