## test-author — pass

- tests for RHYD-1, RHYD-2, FSTG-1, FSTG-2, AMDR-1, AMDR-2, ITER-1, CMBR-1, SKIP-1, DSPK-1, ENTR-1, ENTR-2, FRSH-1, FRSH-2, DLGT-1, CYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: done — added `_frsh2_cycled_starts` count and `assert_eq "[#1805/FRSH-2] ... exactly one stage.start ..."` to the FRSH-2 section of `resume-rehydrate-test.sh`; this assertion fails when `_cycle_dispatch` lacks the `_ZBUILD_RESUME_ACTIVE` guard (cycled emits 2 stage.start events instead of 1).
- answered: lens-scope-code finding 2: nothing to do — Path 4 (ENTR-2) in `resume-entry-points-test.sh` lines 425-554 already tests auto-resume via the `latest` symlink path using `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`; the finding was raised before ENTR-2 (Path 4) was written.
