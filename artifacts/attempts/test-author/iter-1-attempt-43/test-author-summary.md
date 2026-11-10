## test-author — timed_out

- the author did not finish (router_timeout) — what it wrote is kept for the next attempt

- the test files, and the requirements each covers:
- tests/integration/resume-rehydrate-test.sh — DSRHYD-1, DSRHYD-2, DSAMDR-1, DSAMDR-2, DSSKIP-1, DSDSPK-1, DSFRSH-1, DSFRSH-2, DSCYCL-1
- tests/integration/from-stage-rehydrate-test.sh — DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSCYCL-1
- tests/unit/descriptive-id-readers-test.sh — DSFSTG-1
- tests/integration/resume-loop-state-test.sh — DSITER-1, DSCMBR-1, DSCYCL-1
- tests/integration/resume-entry-points-test.sh — DSENTR-1, DSENTR-2, DSCYCL-1
- tests/unit/hydrate-stage-test.sh — DSDLGT-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- not answered: test-author finding 1
- not answered: test-author finding 2
- not answered: acceptance-gate finding 1
- not answered: issue-acceptance finding 1
- not answered: lens-correctness-code finding 2
- not answered: lens-correctness-design finding 1
