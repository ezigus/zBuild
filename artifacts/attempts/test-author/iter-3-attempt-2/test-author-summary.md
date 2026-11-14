## test-author — unusable

- changed 1 test file(s); 5 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- tests/unit/platform-probe-test.sh — DSPRB-1, DSPRB-2, DSPRB-3, DSPRB-4, DSPRB-5, DSDEL-1, DSADR-3
- tests/unit/atomic-write-cost-test.sh — DSBUD-1
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 2 (DSPRB-2 Given: the test sets ZBUILD_PLATFORM=macos after sourcing)**: wrong — Same reasoning as finding 1: compat.sh's `uname`-based assignment overwrites any pre-export on Linux CI, so setting before sourcing leaves `ZBUILD_PLATFORM=linux` at call time and the test cannot distinguish old from new code.
- not answered: test-author finding 1
- not answered: test-author finding 2
- not answered: test-author finding 3
- not answered: test-author finding 4
- not answered: test-author finding 5
- not answered: acceptance-gate finding 1
- not answered: acceptance-gate finding 2
- not answered: issue-acceptance finding 1
- not answered: issue-acceptance finding 2
- not answered: issue-acceptance finding 3
- not answered: issue-acceptance finding 4
- not answered: issue-acceptance finding 5
- not answered: issue-acceptance finding 6
- not answered: issue-acceptance finding 7
