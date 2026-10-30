# Test stage summary

- verdict: fail
- passed: 830
- failed: 1
- exit_code: 1

## Failing files

- tests/unit/core-pipeline-cycle-convergence-test.sh — ✗ cycle exit_when: unrecognized op 'ne' — expected: 0, got: 1

## Failing lines (extracted)

```
[38;2;248;113;113m[1m✗[0m cycle exit_when: unrecognized op 'ne'
  [38;2;248;113;113m✗[0m ne with non-matching value → rc=0 (converged)
    [2mexpected: 0, got: 1[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.OMJN9k/tests/unit/core-pipeline-cycle-convergence-test.sh
  [38;2;250;204;21m[1m⚠[0m cycle.metric.invalid — iter=abc max=3 reason=non_numeric
  [38;2;74;222;128m✓[0m non-numeric iter → terminate (fail-closed)
  [38;2;74;222;128m✓[0m status field eq match → converged
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-5 (the file stopped after SPEC-4), SPEC-8 (the file stopped after SPEC-7): its test never ran on the code from before this change — an earlier step in its test file stops the file there, so it is not shown to fail on the old code
