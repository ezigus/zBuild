## design — fail

- the design fails 11 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Changed `DSCLA-10 covers: RQCLA-3` to `DSCLA-10 covers: RQCLA-9`. RQCLA-9 is the requirement that asks for event emission when `zbuild:claimed` is present.
- answered: test-author finding 1: not mine — The exit-12 failure in `teardown-repeat-signal-test.sh` before DSCLA-1 is a test file organisation issue: DSCLA-9 assertions (integration-level, via the runner) correctly fail on old code and stop the file before DSCLA-1 (unit-level, function call) can run. These belong in separate files. The SPEC descriptions are correct; test separation is the test author's decision.
