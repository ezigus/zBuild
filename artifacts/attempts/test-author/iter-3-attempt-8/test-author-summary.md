## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: wrong — The change to `scripts/lib/run-status-text.sh` appends empty backticks in `_rsc_code_labels_v`, but no requirement in this issue covers that change. Issue-acceptance independently confirmed it is an unasked change ("1 part(s) of the change no requirement asks for"). Writing a test for it would pin behavior no requirement demands and lock in an unrequested change. The test-author must not write tests for unrequested behavior: a test that only fails without an unasked change asserts nothing about the issue's requirements. The correct resolution is for the code stage to revert the unasked change.
- answered: issue-acceptance finding 1: not mine — The failing test in `pipeline-resume-test.sh` ("--from-stage without --resume exits 1") correctly asserts RQFROM-4. It uses `status=in_progress` with a recent timestamp — the same approach as the base code — so the test passes on base code and fails on the branch because the branch narrowed the `--from-stage` guard to `interrupted` only (confirmed in `core/pipeline/runner.sh`: `if [[ "$_fsg_status" == "interrupted" ]]; then`). The test is right; fixing the guard's position is a code change to `core/pipeline/runner.sh`, outside test-author scope.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is exactly right for that scenario. The "all complete" pre-scan path (where `test` has `complete` from an earlier iteration) is not stated in any requirement or SPEC in this contract and is outside the issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The finding is about the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`. My DSFSTG-3 test (S10 in `from-stage-rehydrate-test.sh`) correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for stages after `<s>`. Fixing the implementation guard in `runner.sh` is outside test-author scope.
