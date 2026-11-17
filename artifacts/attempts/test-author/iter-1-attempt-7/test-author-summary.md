## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event." The test greps `config/event-schema.json` directly for the string `"pipeline.refused.claimed"`, which is exactly what the coverage script checks. On base code the string is absent, so the assertion fails for the right reason. Running a full pipeline is DSCLA-3's job. The SPEC's Given/When describe the motivating scenario; the Then is a schema-level assertion.
