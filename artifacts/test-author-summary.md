## test-author — pass

- tests for DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-10, DSCLA-11, DSCLA-13, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8, DSCLA-14

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-13
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not reject pipeline.refused.claimed as an unregistered event name." The emitted-coverage check works by scanning source for literal event names and verifying each is registered in `config/event-schema.json`. Whether it accepts `pipeline.refused.claimed` is decided entirely by whether `"pipeline.refused.claimed"` is in that JSON file. The test greps that file directly — the identical predicate the coverage script applies. On base code the string is absent, so the assertion fails there for the right reason and passes once the implementation adds the event. The Given/When in the SPEC describe the motivating scenario; actually running a full pipeline is DSCLA-3's job. A schema-level assertion for a schema-level Then is correct.
