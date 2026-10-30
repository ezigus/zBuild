# Test stage summary

- verdict: fail
- passed: 318
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-16] manifest provides.events contains plugin.result
  [38;2;74;222;128m✓[0m [SPEC-16] manifest provides.events contains security_lens.failed
  [38;2;248;113;113m✗[0m [SPEC-19] canary: all preceding assertions passed (FAIL==0)
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-1] manifest provides.events includes plugin.result
    [2mplugin.result absent[0m
unit: FAIL plugins/agent/security-lens/tests/security-lens-test.sh
unit: FAIL tests/unit/merge-v2-result-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 94 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-30] push failure → unavailable
  [38;2;74;222;128m✓[0m [SPEC-30] gh pr create failure → unavailable
  [38;2;74;222;128m✓[0m [SPEC-30] gh pr merge failure → unavailable
  [38;2;248;113;113m[1m1 of 55 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — tests/unit/event-schema-emitted-coverage-test.sh was put back to its old version and every test still passed, so it is not what runs the new behaviour — name the file whose code calls it, or write WIRING: none
