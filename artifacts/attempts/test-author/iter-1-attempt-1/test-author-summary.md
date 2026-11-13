## test-author — unusable

- changed 4 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/agent/build/tests/build-test.sh — DSDIFF-1, DSDIFF-2, DSDIFF-3
- tests/unit/route-loop-terminated-reasons-test.sh — DSEND-1, DSLOCK-1
- tests/unit/router-rc-classify-test.sh — DSLOCK-2
- tests/unit/route-one-call-per-try-test.sh — DSLOCK-3
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- no finding was open for it
