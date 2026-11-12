## test-author — unusable

- the check that each assertion tests its SPEC could not be run (unusable)

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: not mine — The test in `pipeline-resume-test.sh` correctly asserts RQFROM-4: `--from-stage intake` without `--resume`, with `status=in_progress` (a recent timestamp triggering `auto_resume`), must exit 1. The test is right. The implementation in `core/pipeline/runner.sh` doesn't meet the requirement — the flat-file auto-resume `elif` fires for `in_progress` state before the `--from-stage` guard can refuse the run, so the runner exits 0. Fixing `runner.sh` is outside the test-author scope.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "member stage 'test' was interrupted before completing; persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is exactly what the GIVEN requires. The edge case described (all-complete pre-scan path where `test.status="complete"` from iter N-1 with `build` already completed in iter N) is not stated in any requirement or design spec in this contract and is beyond this issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The finding is about the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`, an implementation file I cannot modify. The DSFSTG-3 test correctly asserts the observable behavior: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>`, and no `stage.skip` events fire for any stage after `<s>`.
- not answered: issue-acceptance finding 3
