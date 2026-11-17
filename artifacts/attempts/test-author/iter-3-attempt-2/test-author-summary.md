## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — The DSCLA-10 test correctly checks the Then by grepping `config/event-schema.json` for `"pipeline.refused.claimed"`. The event-schema emitted-coverage check (`tests/unit/event-schema-emitted-coverage-test.sh`) works by verifying that every event name emitted in code appears in that JSON file. Checking the schema file directly *is* the coverage check. On base code, `"pipeline.refused.claimed"` is absent from `config/event-schema.json` (verified: only `pipeline.refused.issue_locked` and `pipeline.refused.run_cap` appear near line 17–18), so the assertion fails for the right reason. Running a full pipeline to exercise the Given/When is DSCLA-3's job; DSCLA-10's Then is a schema-registration assertion, not a runtime-execution assertion, and the test proves exactly that.
