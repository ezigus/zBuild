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
- answered: lens-correctness-code finding 2: wrong — `"aborted"` is the status the engine writes for a stage interrupted mid-run. The requirement says "test was interrupted before completing." Using `"complete"` would be testing a hand-made assumption that contradicts what the engine actually writes. The test correctly uses the engine-written value per the rule "data another part of the engine writes is checked against its writer."
- answered: lens-correctness-design finding 1: not mine — this is a concern about the implementation in `core/pipeline/runner.sh` (how `skip_until_stage` and `resume_mode` interact when `--from-stage` names a cycle). The test for DSFSTG-3 asserts the observable behavior: stages after `<s>` emit `stage.start` and no `stage.skip` events are emitted. That is what the code must satisfy regardless of the internal mechanism. No change to the test output is needed.
