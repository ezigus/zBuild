## test-author — pass

- tests for DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-10, DSCLA-11, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event." The coverage check (`tests/unit/event-schema-emitted-coverage-test.sh`) works by scanning code for literal event names and verifying each is in `config/event-schema.json`. The DSCLA-10 test greps that JSON file directly — the identical check the coverage script performs. On base code, `"pipeline.refused.claimed"` is absent from `config/event-schema.json` (verified), so the assertion fails for the right reason. Running a full pipeline is DSCLA-3's job. The Given/When in the SPEC describe the motivating scenario; the Then is a schema-level assertion, and the test proves exactly that.
