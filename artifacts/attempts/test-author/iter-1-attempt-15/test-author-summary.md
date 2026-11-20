## test-author — pass

- tests for DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21, DSCLA-22, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8, DSCLA-14

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: test-author finding 1: done — Added `grep -qF -- "--add-label" "$_dscla18_calls"` as a second condition in the DSCLA-18 assertion. The gh mock writes each CLI argument on its own line, so `--add-label` appears as its own line in the calls file when the implementation adds a label. The test now fails if `--remove-label zbuild:claimed` was called instead of `--add-label zbuild:claimed`.
- answered: test-author finding 2: done — Added `grep -qF -- "--remove-label" "$_dscla20_calls"` as a second condition in the DSCLA-20 assertion. The test now fails if `--add-label zbuild:claimed` was called instead of `--remove-label zbuild:claimed`.
