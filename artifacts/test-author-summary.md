## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — Added a leaf-stage sub-case for DSDSPK-1 in `tests/integration/resume-rehydrate-test.sh`. The new sub-case uses the `resume-minimal` template (intake → build → test, all leaf stages), sets intake=complete and build=pending (k = interrupted leaf stage), resumes via `--resume`, and asserts `stage.start` is emitted for `build` (the leaf stage k). Before the change: no rehydration/skip logic → build never dispatched → `_dspk_leaf_build_starts=0` → `assert 0 > 0` → FAILS. After the change: rehydrate → skip intake → dispatch build → PASSES.
