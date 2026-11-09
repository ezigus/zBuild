## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-red-team-code finding 1: done — Added `cycle.start > 0` assertions for the `cyc` cycle stage in both the DSFRSH-1 (--no-resume sub-case) and DSFRSH-2 (no --resume / in_progress sub-case) sections of `tests/integration/resume-rehydrate-test.sh`. These assertions are non-vacuous: `cycle.start` IS emitted by the current cycle orchestrator in fresh runs (confirmed by `core-pipeline-cycle-orchestrator-test.sh`), so they pass on current code, but would fail if the skip guard erroneously suppresses `cyc`'s dispatch without emitting `stage.skip` — the gap the red-team finding identified. The existing `stage.skip == 0` assertions are kept alongside them, covering the "new code emits stage.skip on fresh runs" bug vector.
- not answered: test-author finding 1
