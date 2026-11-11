## test-author — fail

- DSAMDR-1 cannot be proven by any test — design must rewrite it

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSCYCL-1
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: issue-acceptance finding 1: done — Restored `tests/integration/pipeline-resume-test.sh` to use `status:"in_progress"` (a recent timestamp, `auto_resume` recommendation) for the `--from-stage without --resume` test section, reverting the deliberate weakening to `status:"complete"` that hid the code regression. RQFROM-4 requires refusal "even when the run would otherwise resume by itself"; `in_progress` (recent) is the canonical case. The base code places the `--from-stage` guard before auto-resume processing (base `runner.sh` lines 1736–1741), so this test passes on base code. The branch code moved that guard to after auto-resume, so an `in_progress` run auto-resumes first and the guard never fires — the restored test now fails on the branch code, exposing the regression. The code-stage must restore the guard to its pre-auto-resume position.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted." Using `stage_statuses.test = "aborted"` is exactly right for that GIVEN. The edge case the finding names — `test.status = "complete"` from a prior iteration with `build` already completed in the current iteration — is not stated in any requirement or design spec in this contract and is beyond this issue's acceptance boundary.
- answered: lens-correctness-design finding 1: not mine — The finding is about the interaction between `skip_until_stage` and `resume_mode` inside `core/pipeline/runner.sh`, an implementation file I cannot modify. The DSFSTG-3 test correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for any stage after `<s>`.
