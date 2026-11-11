# Test stage summary

- failed: tests/integration/stage-time-limit-test.sh
- verdict: fail
- passed: 886
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/stage-time-limit-test.sh — ✗ [S1] the stage is stopped near its limit, not after 60s — expected: yes, got: no (16s) (and 1 more failing check in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eGMtJR/tests/integration/stage-time-limit-test.sh
  [38;2;74;222;128m✓[0m [S4] deployed.yaml: design has 1500s
  [38;2;74;222;128m✓[0m [S5] the stage is told its whole-stage limit
  [38;2;74;222;128m✓[0m [S5] ...the default too
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
  [38;2;248;113;113m✗[0m [S1] the stage is stopped near its limit, not after 60s
    [2mexpected: yes, got: no (16s)[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
