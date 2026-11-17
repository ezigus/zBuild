# Test stage summary

- 1 test(s) failed
- verdict: fail
- passed: 146
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/e2e/fork-budget-test.sh
/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Pq7hhb/tests/lib/fork-census.sh: line 26: BASH_XTRACEFD: 7: invalid value for trace file descriptor
  [38;2;74;222;128m✓[0m [SPEC-8] 232 start-up execs ≤ STARTUP_EXECS_BUDGET 234
  start-up per plugin: 12 processes (target 11), 6 execs (target 6)
  [38;2;74;222;128m✓[0m [SPEC-8] each floor is below its budget: the goal still ahead
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 21 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-8] 468 start-up processes ≤ STARTUP_PROCS_BUDGET 465
    [2mexpected: 1, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
