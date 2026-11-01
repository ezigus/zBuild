# Test stage summary

- verdict: fail
- passed: 3
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] intake-result.json carries outcome=broken
    [2mexpected: broken, got: pass[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] reason names intake.md
    [2moutput missing: intake.md[0m
unit: FAIL plugins/agent/intake/tests/intake-result-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 43 tests failed[0m
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — SPEC-1/SPEC-2: its test already passes on the code from before this change, so it cannot tell whether the change was made — make it check something the old code gets wrong; SPEC-4/plugins/agent/intake/tests/intake-result-test.sh: its test does not pass on the new code — the code or the test is wrong
- a test file this change added or changed is far slower than the rest of the suite
