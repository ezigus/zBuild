# Test stage summary

- verdict: fail
- passed: 722
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m SPEC-4: tree-wide, zero cleanup hooks remain
    [2m/home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.ZrTBij/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m [SPEC-3] zero per-stage cleanup hooks remain (ADR-062 §3)
    [2mstill declared by: /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.ZrTBij/plugins/agent/security-lens/manifest.yaml[0m
  [38;2;248;113;113m✗[0m T4: explicit-state run exits 0
    [2mexpected: 0, got: 1[0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.ZrTBij/tests/unit/teardown-purge-scratch-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.ZrTBij/tests/integration/cleanup-release-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.ZrTBij/tests/integration/per-run-state-isolation-test.sh
  [38;2;74;222;128m✓[0m SPEC-4: no plugin declares a cleanup hook any more
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 5 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-5] teardown_run returns rc=0 even when a cleanup hook returns non-zero
  [38;2;0;212;255mSPEC-6: teardown_run never dispatches scope=purge[0m
  [38;2;74;222;128m✓[0m [SPEC-6] teardown_run never dispatches scope=purge (only release)
  [38;2;248;113;113m[1m1 of 12 tests failed[0m
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit → ephemeral dir under the data root
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit wrote nothing under $TMPDIR (#2004)
  [38;2;74;222;128m✓[0m T9: unpinned ad-hoc emit left the shared global default untouched
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
```
