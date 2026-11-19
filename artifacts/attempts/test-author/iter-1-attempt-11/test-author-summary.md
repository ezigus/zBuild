## test-author — unusable

- changed 1 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: lens-sre-code finding 1: done — replaced the hand-written `run-status-comment.txt` fixture in DSCLA-9 with one produced by `rsc_render_header` (sourcing `scripts/lib/run-status-render.sh`, generating a minimal events JSONL, setting `_ZBUILD_CLAIM_HOLDER` before the call, unsetting after). The same writer-generated approach is used for the new DSCLA-15 fixture.
