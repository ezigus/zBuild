## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: build-tests finding 1: done — Added `--resume` to S6's runner invocation in `from-stage-rehydrate-test.sh` (the `--from-stage build` leaf-stage sub-case). RQFROM-4 requires explicit `--resume` for `--from-stage` to function; S5 was already updated for the same reason; S6 was the missed case. The state file already carries `intake=complete` with its artifact on the state branch, so adding `--resume` causes the runner to enter resume mode and the from-stage preflight to rehydrate intake before dispatching build — the DSFSTG-1 assertions remain valid.
- answered: issue-acceptance finding 1: not mine — The `pipeline-resume-test.sh` test at "--from-stage without --resume exits 1" correctly asserts RQFROM-4 using `status=in_progress` with a recent timestamp (same as base code). It passes on base code and fails on the branch because the branch narrowed the guard to `interrupted`-only in `core/pipeline/runner.sh`. The test is right; restoring the guard to its pre-auto-resume position in `runner.sh` is a code change outside test-author scope.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted." `stage_statuses.test = "aborted"` is the correct value for that stated scenario. The edge case where `test` has status `"complete"` from a prior iteration while `build` completes in the current iteration is not named by any requirement or SPEC in this contract and is outside the acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The interaction between `skip_until_stage` and `resume_mode` is an implementation detail inside `core/pipeline/runner.sh`. My DSFSTG-3 test (S10 in `from-stage-rehydrate-test.sh`) correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for stages after `<s>`. Fixing the implementation guard is outside test-author scope.
