## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — RHYD-1, RHYD-2, AMDR-1, AMDR-2, SKIP-1, DSPK-1, FRSH-1, FRSH-2, CYCL-1
- tests/integration/from-stage-rehydrate-test.sh — FSTG-1, FSTG-2, CYCL-1
- tests/integration/resume-loop-state-test.sh — ITER-1
- tests/integration/resume-entry-points-test.sh — ENTR-1, ENTR-2
- tests/unit/hydrate-stage-test.sh — DLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — updated `_setup_path_state` in `resume-entry-points-test.sh` to accept `run_id` as 3rd parameter and create state under `$TEST_TEMP_DIR/${label}-state-root/runs/$run_id/`. Each of paths 1, 2, 3 now defines its run_id variable before calling the helper and passes it as the 3rd argument. The ENTR-1 "Given" (state persisted in `runs/<run_id>/`) is now faithfully reflected in all three test fixtures.
