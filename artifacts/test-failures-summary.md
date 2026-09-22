# Test stage summary

- verdict: fail
- passed: 724
- failed: 1
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m T4: explicit-state run exits 0
    [2mexpected: 0, got: 1[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.vUqrf6/tests/integration/per-run-state-isolation-test.sh
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit → ephemeral dir under the data root
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit wrote nothing under $TMPDIR (#2004)
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit left the shared global default untouched
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
```
