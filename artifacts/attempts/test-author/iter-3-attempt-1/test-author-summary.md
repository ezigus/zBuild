## test-author — pass

- tests for DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- the test files, and the requirements each covers:
- plugins/agent/build/tests/build-test.sh — DSDIFF-1, DSDIFF-2, DSDIFF-3
- tests/unit/route-loop-terminated-reasons-test.sh — DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate finding 1: done — added a [DSLOCK-2]-tagged assertion in `tests/unit/route-loop-terminated-reasons-test.sh` that calls `_router_rc_classify 124` with `rate_limited=0` and asserts `verdict=error`, `reason=router_timeout`; and a [DSLOCK-3]-tagged assertion in the same file that runs `git diff 6a07fa8e..HEAD -- tests/unit/route-one-call-per-try-test.sh` and asserts the diff is empty. Both tags now appear in the test files; all 9 assertions pass.
