## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team-code finding 1: done — Replaced the vacuous `stage.skip=0` assertions for DSFRSH-1 (lines ~844–855) and DSFRSH-2 (lines ~978–988) in `tests/integration/resume-rehydrate-test.sh` with non-vacuous `cycle.start > 0` assertions. The new assertions count `cycle.start` events (the event emitted when the fixture's cycle stage `cyc` is dispatched). If the dispatch-unit skip guard fires unconditionally on a fresh run and skips `intake`, the pipeline cannot proceed to dispatch `cyc`, so `cycle.start` is absent → `assert_gt 0 > 0` → FAILS, which is the failure the requirement demands. After the code change (guard keyed on `resume_mode`), `intake` runs, `cyc` is dispatched, `cycle.start` is emitted → PASSES.
