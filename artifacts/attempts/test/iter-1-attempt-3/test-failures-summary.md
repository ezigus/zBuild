# Test stage summary

- verdict: fail
- passed: 835
- failed: 1
- exit_code: 1

## Failing files

- plugins/agent/intake/tests/intake-result-test.sh — ✗ [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure — expected: 1, got: 0

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] intake-result.json carries outcome=broken
    [2mexpected: broken, got: pass[0m
  [38;2;248;113;113m✗[0m [#1754/SPEC-4] reason names intake.md
    [2moutput missing: intake.md[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Od7SYF/plugins/agent/intake/tests/intake-result-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 43 tests failed[0m
```
