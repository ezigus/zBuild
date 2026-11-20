## test-author — pass

- tests for DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21, DSCLA-22, DSADR-4, DSADR-5, DSADR-6, DSADR-7, DSADR-8, DSCLA-14

- the test files, and the requirements each covers:
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh — DSCLA-1, DSCLA-2, DSCLA-12, DSCLA-3, DSCLA-8, DSCLA-17, DSCLA-10, DSCLA-18, DSCLA-20, DSCLA-19, DSCLA-21
- tests/integration/teardown-repeat-signal-test.sh — DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-11, DSCLA-15, DSCLA-16, DSCLA-13, DSCLA-22
- tests/unit/lint-adr-enforced-by-test.sh — DSADR-7
- Each [code] requirement's test must fail on the code from before this change, and pass once the code is written.
- answered: acceptance-gate-test finding 1: done — Added assertion in `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh` (before `cleanup_test_env`) that `grep -Fxq "core/claim/claim.sh" "$REPO_ROOT/config/shape-change-paths.txt"` and fails if absent. Base code red step: `config/shape-change-paths.txt` on base code does not contain `core/claim/claim.sh` → `assert_fail` fires.
- answered: issue-acceptance-test finding 1: done — Replaced the stale `"claimed label contains 'claimed:' prefix"` assertion (which checked `grep -q "claimed:"` — a substring that `zbuild:claimed` does not contain) with `grep -Fxq "zbuild:claimed"`, asserting the label is exactly `zbuild:claimed`. Also replaced the release check (`grep "claimed:"`, trivially false for `zbuild:claimed`) with `! grep -Fxq "zbuild:claimed"` to properly verify removal. Base code red step: base code writes `claimed:test-machine-1`, not `zbuild:claimed`, so `grep -Fxq "zbuild:claimed"` fails → `assert_fail`.
