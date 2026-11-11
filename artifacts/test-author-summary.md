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
- answered: issue-acceptance finding 1: done — Added S12 sub-case to `tests/integration/from-stage-rehydrate-test.sh` tagged `[#1805/DSFSTG-4]` that exercises the `latest`-symlink auto-resume path with `ZBUILD_STATE_FILE`/`ZBUILD_STATE_DIR` unset, asserting exit 1 and the "--from-stage is only valid with --resume" diagnostic even when state is found via the symlink. This test fails on the current branch code (guard not reached via symlink path) and passes once the guard is extended to cover it.
- answered: lens-correctness-code finding 2: wrong — `"aborted"` is exactly the status `_cycle_state_write_member_atomic` writes for an interrupted cycle member, confirmed in the base `cycle-orchestrator.sh`. DSCMBR-1 tests the standard interrupted-member case (build=complete, test=aborted). The "all complete" edge case — where every member carries `complete` from a prior pass — is beyond this issue's stated requirements. No ISSUE REQUIREMENT or REQUIREMENTS item names or implies that edge case.
- answered: lens-correctness-design finding 1: not mine — this concerns the internal interaction of `skip_until_stage` and `resume_mode` in `core/pipeline/runner.sh`. The DSFSTG-3 test correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for stages after `<s>` and no `stage.skip` events fire. The internal fix mechanism belongs to the code stage.
