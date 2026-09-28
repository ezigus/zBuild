# Test stage summary

- verdict: fail
- passed: 742
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/discover-plugins-memo-test.sh — ✗ [SPEC-2] a warm repeat call costs under 100ms (was ~1470ms) — expected: 1, got: 0

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-2] a warm repeat call costs under 100ms (was ~1470ms)
    [2mexpected: 1, got: 0[0m
unit: FAIL /Users/ericziegler/.zbuild/repos/ezigus/zBuild/issues/1847/runs/20260928102849-23575/scratch/test/zbuild-test-stage.4559rG/tests/unit/discover-plugins-memo-test.sh
  [38;2;74;222;128m✓[0m [SPEC-3] GUARD: a different plugins root resolves to its own tree
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 4 tests failed[0m
```
