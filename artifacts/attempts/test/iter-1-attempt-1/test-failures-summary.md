# Test stage summary

- verdict: fail
- passed: 751
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/deployed-template-e2e-test.sh — ✗ deploy: the engine provided no ZBUILD_ARTIFACT_DIR — nowhere to write a result — expected: 0, got: 1

## Failing lines (extracted)

```
[38;2;248;113;113m[1m✗[0m deploy: the engine provided no ZBUILD_ARTIFACT_DIR — nowhere to write a result
  [38;2;248;113;113m✗[0m [SPEC-9] deploy_agent_run exits 0 in dry-run
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-9] deploy-result.json written
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/deployed-template-e2e.rStZOV/state/artifacts/deploy-result.json[0m
  [38;2;248;113;113m✗[0m [SPEC-9] deploy-result.json verdict=deployed
    [2mexpected: deployed, got: [0m
[38;2;248;113;113m[1m✗[0m validate: missing required input deploy-result.json
  [38;2;248;113;113m✗[0m [SPEC-9] validate_agent_run exits 0 in dry-run
  [38;2;248;113;113m✗[0m [SPEC-9] validate-result.json verdict=healthy
    [2mexpected: healthy, got: error[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.eucKFa/tests/integration/deployed-template-e2e-test.sh
  [38;2;248;113;113m[1m5 of 27 tests failed[0m
```
