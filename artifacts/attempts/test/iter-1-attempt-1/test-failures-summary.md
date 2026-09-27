# Test stage summary

- verdict: fail
- passed: 747
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/deployed-template-e2e-test.sh — ✗ validate: missing required input deploy-result.json — expected: 0, got: 1

## Failing lines (extracted)

```
[38;2;248;113;113m[1m✗[0m validate: missing required input deploy-result.json
  [38;2;248;113;113m✗[0m [SPEC-9] validate_agent_run exits 0 in dry-run
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-9] validate-result.json verdict=healthy
    [2mexpected: healthy, got: error[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.nxLQV0/tests/integration/deployed-template-e2e-test.sh
  [38;2;74;222;128m✓[0m [SPEC-9] monitor_stage_run exits 0 in dry-run
  [38;2;74;222;128m✓[0m [SPEC-9] monitor-report.json written
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 25 tests failed[0m
```
