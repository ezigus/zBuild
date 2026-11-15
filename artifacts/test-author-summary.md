## test-author — pass

- tests for DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-1, DSADR-2, DSADR-3, DSBUD-1, DSBUD-2

- the test files, and the requirements each covers:
- tests/unit/platform-probe-test.sh — DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- tests/unit/atomic-write-cost-test.sh — DSBUD-1
- tests/e2e/fork-budget-test.sh — DSBUD-2
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- not answered: test-author finding 1
