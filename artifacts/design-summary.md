## design — fail

- the design fails 1 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: test-author finding 1: not mine — The exit 12 is caused by DSCLA-9 assertions correctly failing on old code (expected behavior for a [code] SPEC), which stops the test file before DSCLA-1's assertion can be checked. DSCLA-1 tests `zbuild_claim_acquire` directly (a new function, not yet present on old code) and belongs in its own unit test; DSCLA-9 tests via the runner and belongs in an integration test. Putting them in the same file means the first failure stops the second from running. The SPEC descriptions are correctly written and unambiguous; test file separation is the test author's decision, not mine.
