# Test stage summary

- verdict: fail
- passed: 5
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
unit: FAIL tests/integration/runner-release-exit-paths-test.sh
  [38;2;74;222;128m✓[0m [SPEC-6] the blocked hook does not outlive the run
  [38;2;0;212;255mSPEC-6b: a hook child that ignores TERM does not outlive the run[0m
  [38;2;74;222;128m✓[0m [SPEC-6b] a hook child that ignores TERM does not outlive the run
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
