## test-author — unusable

- changed 1 test file(s); 1 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: TAFND-3: done** — Replaced the DSCLA-19 test section with a stub-based approach. The stub is created in `$TEST_TEMP_DIR/plugins-dscla19/claim-coordinator/stub/` with a `manifest.yaml` (registering unique hook function names `_dscla19_stub_claim` etc.) and a `plugin.sh` (whose `_dscla19_stub_claim` writes a marker AND returns `{"acquired": true}` on stdout). `ZBUILD_PLUGINS_ROOT` is set to the stub's directory and the stub's plugin.sh is sourced. The test then verifies: (1) the marker was written (coordinator hook was called), (2) no direct gh calls. Unique function names prevent collision with the loaded `claim_coordinator_*` from plugin.sh — no guard-bypass re-sourcing needed in cleanup.
- answered: build-tests finding 1: wrong** — The explicit `source "$REPO_ROOT/core/claim/claim.sh"` block was already added in iteration 9 (the guarded block at lines 35–38 of the current file). The transitive reliance on plugin.sh sourcing claim.sh has been eliminated. This finding described a future concern, not the current state.
- answered: acceptance-gate-test finding 1: not mine** — No SPEC in this contract (DSCLA-1 through DSCLA-22) asks for a test that `core/claim/claim.sh` is listed in `config/shape-change-paths.txt`. My own findings TAFND-1 and TAFND-2 established this, and I removed those assertions. If this entry is required, the design must state it in a SPEC.
