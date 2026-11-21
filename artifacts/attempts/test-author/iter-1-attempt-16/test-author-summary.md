## test-author — unusable

- changed 1 test file(s); 2 finding(s) about its assertions are open — the next try fixes them

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: build-tests finding 1: done — Added an explicit, guarded `source "$REPO_ROOT/core/claim/claim.sh"` block after `source plugin.sh` in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`. The guard `if [[ -f "$REPO_ROOT/core/claim/claim.sh" ]]` means the source is skipped on base code (where the file does not exist), so `zbuild_claim_acquire` remains undefined there and the DSCLA-1/-2/-3/-8 blocks fail on rc≠0 — the intended red step. On new code the file exists, is sourced explicitly, and the tests pass. `core/claim/claim.sh` has an idempotent load guard so re-sourcing after plugin.sh's transitive import is a no-op.
- answered: acceptance-gate-test finding 1: wrong — The assertion that checks for `core/claim/claim.sh` in `config/shape-change-paths.txt` was added in the previous pass (iteration 8) and IS present in the unit test file (before `cleanup_test_env`). It uses `grep -Fxq "core/claim/claim.sh" "$REPO_ROOT/config/shape-change-paths.txt"` and fires `assert_fail` if absent; on the base code the entry is not present, so the test fails there. The finding was opened before that fix landed and the system had not yet re-evaluated it.
