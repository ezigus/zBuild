# Test stage summary

- verdict: fail
- passed: 844
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/run-status-comment-quiet-test.sh — ✗ [#1806/Q2] one POST, then one PATCH for the one real change — expected: 2, got: 3

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1806/Q2] one POST, then one PATCH for the one real change
    [2mexpected: 2, got: 3[0m
  [38;2;248;113;113m✗[0m [#1806/Q2] exactly one PATCH
    [2mexpected: 1, got: 2[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.1lHXEy/tests/unit/run-status-comment-quiet-test.sh
  [38;2;74;222;128m✓[0m [#1806/Q3] events.jsonl did not grow
  [38;2;74;222;128m✓[0m [#1806/Q3] a real event still updates the comment
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 10 tests failed[0m
```
