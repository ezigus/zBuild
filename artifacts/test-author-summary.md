## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSCYCL-1
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: wrong — `"aborted"` is exactly the status `_cycle_state_write_member_atomic` writes for an interrupted cycle member, confirmed in `cycle-orchestrator.sh` base code at the SIGINT/SIGTERM paths. DSCMBR-1 tests that the *interrupted* member is dispatched — if `test` were `"complete"`, the skip guard would apply and it would not be dispatched. The "all-complete pre-scan path" is a different scenario (all members complete → iteration is done, nothing to resume) that DSCMBR-1 does not cover.
- answered: lens-correctness-design finding 1: not mine — this is about the interaction between `skip_until_stage` and `resume_mode` in `core/pipeline/runner.sh` implementation. The DSFSTG-3 test correctly asserts the observable requirement: stages after `<s>` emit `stage.start` (or `cycle.start`) and no `stage.skip` events fire. The internal fix mechanism belongs to the code stage, not the test stage.
