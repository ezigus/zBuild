## test-author — timed_out

- the author did not finish (router_timeout) — what it wrote is kept for the next attempt

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-4, DSCLA-8
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- no finding was open for it
