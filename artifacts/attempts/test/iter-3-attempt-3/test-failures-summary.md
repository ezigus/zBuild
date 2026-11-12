# Test stage summary

- 1 test(s) failed
- verdict: fail
- passed: 5
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/integration/pipeline-resume-test.sh
  [38;2;248;113;113m✗[0m --from-stage without --resume says it needs --resume
    [2moutput missing: only valid with --resume[0m
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 23 tests failed[0m
  [38;2;248;113;113m✗[0m --from-stage without --resume exits 1
    [2mexpected: 1, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
