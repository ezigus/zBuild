## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-10
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — added `# Then:` section heading (with a preceding blank line) between the `# When: rsc_render_header is called with the run id and holder string` line and the `if grep -qF '<!-- zbuild-holder:...'` assertion block in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`.
- answered: test-author finding 2: done — added `# And: no stage was dispatched` section heading immediately before the `if [[ ! -e "$_DSCLA9_STARTED" ]]; then` block in `tests/integration/teardown-repeat-signal-test.sh`, separating the no-stage-dispatched assertions from the exit-code `# Then:` section above them.
