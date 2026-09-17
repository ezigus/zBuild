# Test stage summary

- verdict: fail
- passed: 691
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
[38;2;248;113;113m[1m✗[0m LLM rate-limited — resets 12pm (UTC) (model=claude-opus-4-7 tier=T3) — diagnostic: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.cielic/.zbuild-nested-state/artifacts/stage-io/router-sync-error.raw-claude-output.json
[38;2;250;204;21m[1m⚠[0m security_lens_run: router rc=1 (recoverable); using empty findings
  [38;2;248;113;113m✗[0m R1: stub is false after real LLM path
    [2mexpected: false, got: absent[0m
  [38;2;248;113;113m✗[0m [SPEC-3] router-fatal path writes v2 result (OUTPUT_R7 missing)
lint: FAIL (npm run lint)
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.cielic/plugins/agent/security-lens/tests/security-lens-test.sh
```
