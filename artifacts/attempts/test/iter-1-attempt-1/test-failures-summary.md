# Test stage summary

- verdict: fail
- passed: 807
- failed: 2
- exit_code: 1

## Failing files

- tests/unit/lint-test-errexit-test.sh — ✗ [L5] the real tree passes — expected: 0, got: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [L5] the real tree passes
    [2mexpected: 0, got: 1[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.BonH1e/tests/unit/lint-test-errexit-test.sh
lint: FAIL (npm run lint)
lint-test-errexit: tests/integration/cycle-member-unfinished-no-convergence-test.sh:142 turns stop-on-error on in a file that runs without it (header: set -uo pipefail) — an expected non-zero rc after this line kills the file; use 'cmd || rc=$?' instead
lint-test-errexit: 1 file(s) switch stop-on-error on mid-file
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
lint-llm-envelope: OK — 60 plugin source(s) checked, no markdown-document envelope fields
lint-verdict-classify: 34 manifest(s) checked, all declared verdicts classify
lint-disposition-classify: 1 manifest(s) checked, all declared failure classes classify
lint-silenced-redirect: clean
```
