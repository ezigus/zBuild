# Test stage summary

- verdict: fail
- passed: 4
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1944/SPEC-6] ADR-054 §11 content describes the per-run limit
    [2m§11 body does not contain max_run_s/wall-clock/per-run — may describe an unrelated topic[0m
unit: FAIL tests/unit/run-limit-precedence-test.sh
  [38;2;74;222;128m✓[0m [#1944/SPEC-6] lint-adr-enforced-by passes (ADR citations all resolve)
  [38;2;0;212;255m[#1944/SPEC-6] lint-test-errexit: no mid-file set -e in test files[0m
  [38;2;74;222;128m✓[0m [#1944/SPEC-6] lint-test-errexit passes (no mid-file set -e, npm run lint subset)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 45 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — tests/unit/run-limit-precedence-test.sh/tests/unit/run-limit-precedence-test.sh: its test does not pass on the new code — the code or the test is wrong
