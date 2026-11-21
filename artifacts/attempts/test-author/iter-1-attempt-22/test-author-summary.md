## test-author — unusable

- changed 2 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21, DSCLA-23
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-7: done — Added a `# Cleanup` section at the end of the DSCLA-2 block in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`. It restores `ZBUILD_CLAIM_MACHINE_ID` to `"test-machine-1"` and unsets `ZBUILD_RUN_ID`. The GITHUB_* vars set by the dscla2b sub-scenario are intentionally left for DSCLA-12 to use (as the comment notes) — DSCLA-12 has its own cleanup section that unsets them. An earlier version of the fix unset the GITHUB_* vars in the DSCLA-2 cleanup, which broke DSCLA-12 (which relies on them); that over-unset was corrected.
- answered: TAFND-8: done — Removed the untagged 4-line `assert_pass`/`assert_fail` block that checked `_DSCLA7_STARTED` as a validity guard in the DSCLA-7 scenario. The synchronization wait loop that waits for `_DSCLA7_STARTED` before sending SIGTERM was kept — it is setup timing, not an assertion.
- answered: TAFND-9: done — Removed the untagged block that checked `_DSCLA13_STARTED` as a validity guard in the DSCLA-13 scenario. The synchronization wait loop for `_DSCLA13_STARTED` was kept for setup timing.
