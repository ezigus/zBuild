## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: wrong — The DSCMBR-1 requirement's GIVEN explicitly states "persisted state records build as complete and test as aborted within iter k." Using `stage_statuses.test = "aborted"` is correct for the stated scenario. The "all complete" pre-scan path (where test has status "complete" from iter N-1 and build already completed in iter N) is not stated in any requirement or SPEC in this contract. Testing an edge case beyond the contract's scope in a contract test would make the assertion describe behavior the requirement does not demand.
- answered: lens-correctness-design finding 1: not mine — The finding concerns `skip_until_stage`/`resume_mode` interaction in `core/pipeline/runner.sh` — an implementation file outside the test folders. My DSFSTG-3 test (S10 in `tests/integration/from-stage-rehydrate-test.sh`) correctly asserts the observable requirement: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for stages after `<s>`. Fixing the implementation guard in `runner.sh` is outside test-author scope.
