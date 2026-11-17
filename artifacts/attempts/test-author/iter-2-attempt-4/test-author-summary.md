## test-author — unusable

- changed 0 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event." The emitted-coverage check works by scanning source for literal event names and verifying each is in `config/event-schema.json`. The DSCLA-10 test greps that JSON file directly — the identical check the coverage script performs. On base code `"pipeline.refused.claimed"` is absent from `config/event-schema.json` (verified: `pipeline.refused.issue_locked` and `pipeline.refused.run_cap` are present, but not `pipeline.refused.claimed`), so the assertion fails there for the right reason. Running a full pipeline and emitting the event is DSCLA-3's job. The DSCLA-10 Then is a schema-level assertion, and the test proves exactly that.
- answered: acceptance-gate finding 1: not mine — no SPEC in this issue (DSCLA-1 through DSCLA-11, DSADR-7) mentions `config/shape-change-paths.txt`. Writing a test for it would exceed "the requirements below." The issue-acceptance stage reached the same conclusion: no requirement in this issue asks for that entry at all. The fix (adding a test for shape-change-paths.txt content, or removing the spurious entry) belongs to whichever stage can amend the code or requirement scope.
