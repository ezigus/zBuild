## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: acceptance-gate finding 1: done — Changed DSLOCK-3 from `[done]` to `[no-code]`. The root conflict: adding `[DSLOCK-3]` as a co-tag to the O4 assertions in `route-one-call-per-try-test.sh` changes those assertions, violating RQLOCK-4. The fix removes the conflict by making DSLOCK-3 a `[no-code]` SPEC whose test lives in `route-loop-terminated-reasons-test.sh` (already touched by DSEND-1) and asserts that `[O4]` labels still appear in `route-one-call-per-try-test.sh` unchanged — that file is never modified. For DSLOCK-2, the design already specifies Given/When/Then correctly; the test-author must add `[DSLOCK-2]` tags to the existing T2 assertions in `tests/unit/router-rc-classify-test.sh` — that is test-author execution work, not a design change.
