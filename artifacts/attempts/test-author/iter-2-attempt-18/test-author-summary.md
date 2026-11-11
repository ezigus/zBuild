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
- answered: issue-acceptance finding 1: wrong — The test already uses `status: "interrupted"` (not `status=complete`) at line 778 of `from-stage-rehydrate-test.sh`. Both S11 (flat ZBUILD_STATE_FILE path) and S12 (latest-symlink path) use `status=interrupted`, which satisfies DSFSTG-4's stated WHEN clause ("even when a state file with status=interrupted exists"). The finding was raised against an older version of the test; the current test correctly covers the stated auto-resume conditions. The concern about `status=in_progress` is a code-stage gap, not a test gap.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is the correct setup for that GIVEN. The 'all complete' edge case (where `test.status = "complete"` from iter N-1 and `build` already completed in iter N) is not stated in any requirement or design spec in this contract and is beyond this issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The finding concerns the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`, which I cannot modify. The DSFSTG-3 test correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for any stage after `<s>`.
