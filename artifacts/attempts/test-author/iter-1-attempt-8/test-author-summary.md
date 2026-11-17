## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event." The emitted-coverage check (`tests/unit/event-schema-emitted-coverage-test.sh`) works by scanning source for literal event names and verifying each is in `config/event-schema.json`. The DSCLA-10 test greps that JSON file directly for `"pipeline.refused.claimed"` — the identical check. On base code that string is absent from the schema file (confirmed at `/home/runner/work/_temp/zbuild-state/base-code/config/event-schema.json`), so the assertion fails for the right reason. The Given/When describe the motivating scenario; the Then is a schema-level assertion. Running a full pipeline and emitting the event is DSCLA-3's job, not DSCLA-10's.
