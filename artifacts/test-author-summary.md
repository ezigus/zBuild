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
- answered: acceptance-gate finding 1: wrong — DSFSTG-4 is classified `[done]` in the design stage output, meaning its test must pass on the code from before this change (the base code already has the guard). The acceptance gate is correct that the test passes on before-code, but that is the expected property for a `[done]` requirement, not a defect. No change needed.
- answered: lens-correctness-code finding 2: wrong — The DSCMBR-1 test sets `stage_statuses.test = "aborted"` because that is what the engine actually writes for a stage that was interrupted mid-run. The requirement says "test was interrupted before completing" — `"aborted"` is the correct status written by the engine for such a stage. Using `"complete"` would not test the actual engine-written state; it would test a hand-made assumption. The test correctly uses `"aborted"` per the requirement that "data another part of the engine writes is checked against its writer."
- answered: lens-correctness-design finding 1: not mine — this is a concern about the implementation in `core/pipeline/runner.sh` (how `skip_until_stage` and `resume_mode` interact when `--from-stage` names a cycle), not about the test assertions. The test for DSFSTG-3 correctly asserts the observable outcome (stages after `<s>` are dispatched, no stage.skip emitted), which is what the code must satisfy regardless of its internal mechanism.
