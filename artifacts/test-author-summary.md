## test-author — pass

- tests for DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSAMDR-1, DSAMDR-2, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSFRSH-1, DSFRSH-2, DSDLGT-1, DSCYCL-1

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSCYCL-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — The test correctly uses `stage_statuses.test = "aborted"` for iter-2. The design stage accepted this correction and updated DSCMBR-1's Given to say "aborted" (the value `_cycle_state_write_member_atomic` actually writes for an interrupted stage). Using "in_progress" would test with a value the production code never writes, making the skip-guard assertion (`== "complete"`) meaningless. The absence of iter-1 test status in state is also correct: iter-1 is a fully completed iteration; DSCMBR-1 concerns behavior within the interrupted iter (iter-2) only. The test is right; the design spec was updated to match it.
- not answered: lens-performance-code finding 1
- not answered: lens-red-team-code finding 1
- not answered: lens-red-team-code finding 2
- not answered: lens-red-team-code finding 3
- not answered: lens-correctness-code finding 1
- not answered: lens-correctness-code finding 2
- not answered: lens-correctness-code finding 3
- not answered: lens-scope-code finding 1
- not answered: lens-sre-code finding 1
- not answered: lens-sre-code finding 2
- not answered: lens-correctness-design finding 1
