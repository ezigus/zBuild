# Test stage summary

- verdict: fail
- passed: 3
- failed: 2
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
    [2mstill declared by: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zeNYgq/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
    [2m/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zeNYgq/plugins/agent/security-lens/manifest.yaml[0m
unit: FAIL tests/integration/cleanup-release-test.sh
unit: FAIL tests/unit/teardown-purge-scratch-test.sh
  [38;2;74;222;128m✓[0m [SPEC-5] teardown_run returns rc=0 even when a cleanup hook returns non-zero
  [38;2;0;212;255mSPEC-6: teardown_run never dispatches scope=purge[0m
  [38;2;74;222;128m✓[0m [SPEC-6] teardown_run never dispatches scope=purge (only release)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
  [38;2;74;222;128m✓[0m SPEC-4: no plugin declares a cleanup hook any more
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
```
