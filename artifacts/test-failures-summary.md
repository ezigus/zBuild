# Test stage summary

- verdict: fail
- passed: 285
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL plugins/agent/security-lens/tests/security-lens-test.sh
[38;2;248;113;113m[1m✗[0m LLM rate-limited — resets 3pm (UTC) (model=claude-opus-4-7 tier=T3) — diagnostic: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.OQ6UEF/.zbuild-nested-state/artifacts/stage-io/router-sync-error.raw-claude-output.json
  [38;2;248;113;113m✗[0m R1: stub is false after real LLM path
    [2mexpected: false, got: absent[0m
  [38;2;248;113;113m✗[0m [SPEC-3] router-fatal path writes v2 result (OUTPUT_R7 missing)
```
