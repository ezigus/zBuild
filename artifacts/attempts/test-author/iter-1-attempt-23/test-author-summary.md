## test-author — unusable

- changed 1 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1, CMBR-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/integration/cycle-member-dispatch-events-test.sh — FRSH-1
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: nothing to do — FRSH-2 tests the dispatch-unit skip guard being conditional on `resume_mode` (intake dispatches on a fresh run; no stage.skip). The design explicitly accepts `stage.start` for cycle members at `_cd_iter > 0` on all runs (design note says to update the test to EXPECT it). No assertion that cycle members do NOT emit `stage.start` is appropriate.
- answered: lens-scope-code finding 2: nothing to do — ENTR-2 PATH 4 is already present at lines 425-554 of `resume-entry-points-test.sh`, using `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR ZBUILD_STATE_ROOT=...` to exercise the `latest`-symlink auto-resume branch. The finding was written before the sub-case was added.
- answered: issue-acceptance finding 1: done — added `[#1805/FRSH-1]` assertion to `cycle-member-dispatch-events-test.sh` Section 1 expecting `stage.start` count=2 for cycle members (build, review) on a fresh run. The design says `_cycle_dispatch`'s `_cd_iter > 0` guard fires for all iters in a fresh run (iter 1 > 0), so both members emit `stage.start`. This confirms GUAR-1: cycle member stages ARE dispatched from stage 1. The test fails on old code (no guard → count=0 ≠ 2) and passes after the code change.
