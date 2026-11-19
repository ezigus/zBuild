## test-author — unusable

- changed 1 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-sre-code finding 1: done — the fix was already applied in the worktree. `teardown-repeat-signal-test.sh` lines 369–382 source `run-status-render.sh` and call `rsc_render_header` to write `run-status-comment.txt` for the DSCLA-9 fixture. The same approach is used for the DSCLA-15 fixture (lines 634–643). No hand-written heredoc exists for the holder comment.
- answered: test-author finding 1: done — restructured the DSCLA-10 block in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`. Each section now has code: Given sets `_dscla10_schema` and `_dscla10_runner`; When captures `_dscla10_registered=false/true` from the grep; Then asserts on `_dscla10_registered`. Failure message now includes runner.sh occurrence count for diagnostic context. Test behavior is identical — fails on base code (event absent from schema), passes after the change.
- answered: test-author finding 2: wrong — DSCLA-11 is marked [done]: its test must pass on both old and new code. The test calls `rsc_render_header` directly for all three exit paths (normal, failure, signal). This IS the render function; if it regressed the test would fail. Running the full runner for DSCLA-11 would duplicate DSCLA-5/DSCLA-6/DSCLA-7, which already exercise all three exit paths with the actual runner. The [done] contract requires passing, not failing before — the current test satisfies that.
