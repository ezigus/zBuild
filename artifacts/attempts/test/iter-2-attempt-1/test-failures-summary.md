# Test stage summary

- verdict: fail
- passed: 54
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
  ✗ impact router.max_turns is 45 (raised from the 25 default)
    expected: 45, got: 
  ✗ impact router.timeout_s is 600 (right-sized 180→600, #1242)
    expected: 600, got: 
  ✗ impact max_turns should exceed 25
    got: 
  [38;2;248;113;113m✗[0m [SPEC-2] simple.yaml flow count excludes both always-run stages
    [2mexpected: 20, got: 19[0m
unit: FAIL tests/unit/impact-max-turns-test.sh
unit: FAIL tests/unit/template-always-run-test.sh
  ──────────────────────────────────────────
  3 of 3 tests failed
  [38;2;74;222;128m✓[0m [SPEC-7] and timeout_s after it still parses
  [38;2;74;222;128m✓[0m [SPEC-7] inline-form roles: is captured on an always-run section too
  [38;2;74;222;128m✓[0m [SPEC-7] and its timeout_s parses as well
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 18 tests failed[0m
```
