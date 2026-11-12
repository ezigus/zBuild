## test-author — unusable

- the check that each assertion tests its SPEC could not be run (unusable)

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: wrong — The branch change to `scripts/lib/run-status-text.sh` appends empty backticks in `_rsc_code_labels_v`; no requirement in this issue covers it. Issue-acceptance independently confirmed it is an unasked change. Adding a test for it would assert behavior no requirement demands and lock in an unrequested change. The correct resolution is for the code stage to revert the change. Test-author must not write tests for unrequested behavior: a test that only fails without an unasked change asserts nothing about the issue's requirements.
- answered: issue-acceptance finding 1: not mine — `pipeline-resume-test.sh`'s `--from-stage without --resume exits 1` section uses `status=in_progress` with a current timestamp, identical to the base code. The test passes on base code and fails on branch code because the branch narrowed the `--from-stage` guard to `interrupted` only (or moved it after auto-resume processing). That is a code regression in `core/pipeline/runner.sh`. The test correctly asserts RQFROM-4; restoring the guard's position is outside test-author scope.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is exactly right for that scenario. The "all complete" pre-scan path (where `test` has status `complete` from a prior iteration, with `build` already done in the current iteration) is not stated in any requirement or SPEC in this contract and is outside the issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — This is about the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`. My DSFSTG-3 test (S10 in `from-stage-rehydrate-test.sh`) correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for stages after `<s>`. Fixing the implementation guard placement is outside test-author scope.
