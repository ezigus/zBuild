## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not reject pipeline.refused.claimed as an unregistered event name." The emitted-coverage check (`tests/unit/event-schema-emitted-coverage-test.sh`) works by scanning source for literal event names and verifying each is registered in `config/event-schema.json`. Whether the check accepts `pipeline.refused.claimed` is decided entirely by whether `"pipeline.refused.claimed"` is in that JSON file. The test greps that file directly — the identical predicate the coverage script applies. On base code the string is absent (`pipeline.refused.issue_locked` and `pipeline.refused.run_cap` are present, but not `pipeline.refused.claimed`), so the assertion fails there for the right reason and passes once the implementation adds the event. The Given/When in the SPEC describe the motivating scenario; actually running a full pipeline is DSCLA-3's job. A schema-level assertion for a schema-level Then is correct.
- answered: acceptance-gate finding 1: wrong — no SPEC in this issue (DSCLA-1 through DSCLA-11, DSADR-7) mentions `config/shape-change-paths.txt`. Writing a test for it would exceed "do what has been asked; nothing more, nothing less." The behavioral rules forbid adding more than asked.
