## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-correctness-code finding 2: wrong — DSCMBR-1's GIVEN explicitly states "persisted state records build as complete and test as aborted within iter k." Using `stage_statuses.test = "aborted"` is the correct fixture for that exact scenario (`_cid_nc = 1`, the interrupted-member path). The "all complete" edge case — where every member's status is "complete" from a previous iteration, requiring the Scenario A/B disambiguator (`_cid_nc -eq 0`) — is not stated in any requirement or SPEC in this contract. RQLOOP-1 is scoped to "a run interrupted mid-round," meaning at least one member is non-complete. Testing an edge case beyond the contract's scope in a contract assertion would make the test describe behavior no requirement demands, violating the rule "assert what is required, never what the code happens to do."
- answered: lens-correctness-design finding 1: not mine — The finding describes an implementation interaction between `skip_until_stage` and `resume_mode` in `core/pipeline/runner.sh`. My DSFSTG-3 test (S10 in `tests/integration/from-stage-rehydrate-test.sh`) correctly asserts the observable requirement end-to-end: `stage.start` (or `cycle.start`) is emitted for each stage after `<s>` and no `stage.skip` events fire for any stage after `<s>`. Whether that observable result is achieved by clearing `skip_until_stage` correctly, by clearing `resume_mode`, or by another mechanism is an implementation matter in `core/pipeline/runner.sh` — outside test-author scope.
