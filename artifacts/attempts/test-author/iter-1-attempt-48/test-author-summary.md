## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: done — `tests/integration/pipeline-resume-test.sh` already has `status:"in_progress"` with `$now` (a recent timestamp) in the `--from-stage without --resume` section (line 324). This was restored in a prior round. The test uses the canonical auto-resume trigger so it catches any code regression that moves the `--from-stage` guard to after auto-resume processing.
- answered: lens-correctness-code finding 2: wrong — The DSCMBR-1 requirement GIVEN explicitly states "member stage 'test' was interrupted before completing; persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is exactly what the GIVEN requires. The edge case the finding names (test.status="complete" from iter N-1 with build already complete in iter N) is not stated in any requirement or design spec in this contract and is beyond this issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The finding is about the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`, an implementation file I cannot modify. The DSFSTG-3 test correctly asserts the observable behavior required by the spec: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for any stage after `<s>`.
- not answered: test-author finding 1
- not answered: test-author finding 2
- not answered: test-author finding 3
