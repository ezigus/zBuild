# Test stage summary

- verdict: fail
- passed: 689
- failed: 4
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
    [2m/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.kaeg7f/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
    [2mstill declared by: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.kaeg7f/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m R1: stub is false after real LLM path
    [2mexpected: false, got: absent[0m
  [38;2;248;113;113m✗[0m [SPEC-3] router-fatal path writes v2 result (OUTPUT_R7 missing)
lint: FAIL (npm run lint)
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.kaeg7f/tests/unit/teardown-purge-scratch-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.kaeg7f/tests/integration/cleanup-release-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.kaeg7f/plugins/agent/security-lens/tests/security-lens-test.sh
```
