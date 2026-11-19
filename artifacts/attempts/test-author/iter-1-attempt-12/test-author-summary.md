## test-author — unusable

- changed 0 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-sre-code finding 1: done — the fix was already applied in the worktree. `teardown-repeat-signal-test.sh` lines 369–382 source `run-status-render.sh` and call `rsc_render_header` to write `run-status-comment.txt` for the DSCLA-9 issue, not a hand-written heredoc. The same approach is used for the DSCLA-15 fixture (lines 634–643). The hand-written block is gone.
- answered: test-author finding 1: wrong — DSCLA-10's Then is "the check exits without reporting pipeline.refused.claimed as an unregistered event name." The emitted-coverage check works by scanning code for literal event names and verifying each is in `config/event-schema.json`. Whether the check accepts the event is determined entirely by whether `"pipeline.refused.claimed"` is present in that JSON file. Grepping the file directly is the same check the coverage script performs, and the test fails on base code (the string is absent) for exactly the right reason. Running the full coverage script would add a whole test-runs-another-test dependency and test the same thing.
- answered: test-author finding 2: wrong — DSCLA-11 is marked [done]: "its test must pass after this change; it need not fail before." The test verifies `rsc_render_header` (the function that IS the run-status comment renderer) shows non-running status for terminal events. If that function regressed the test would fail. For a [done] requirement, the runner already calls this function (evidence: `rsc_finalize_body` in `scripts/lib/run-status-render.sh`). Running the full runner for DSCLA-11 would duplicate DSCLA-5, DSCLA-6, DSCLA-7 which already exercise the runner on all three exit paths. The [done] contract requires passing on both old and new code — the test satisfies that.
