# Test stage summary

- verdict: fail
- passed: 818
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/always-run-exit-paths-test.sh — ✗ [#1801/SPEC-5] persist hook was entered (always_run persist stage dispatched) — file not found: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.H9pkiA/spec5p-entered
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1801/SPEC-5] persist hook was entered (always_run persist stage dispatched)
    [2mfile not found: /home/runner/work/_temp/zbuild-state/scratch/test/zb-always-run-exit.H9pkiA/spec5p-entered[0m
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.RrtDdP/tests/integration/always-run-exit-paths-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.RrtDdP/tests/integration/runner-release-exit-paths-test.sh
  [38;2;0;212;255m[SPEC-6][guard] an unresolvable role emits an event instead of failing silently[0m
  [38;2;74;222;128m✓[0m [SPEC-6] stage.always_run.unresolved is emitted
  [38;2;74;222;128m✓[0m [SPEC-6] an unresolvable always-run stage does not fail the run
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 13 tests failed[0m
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] always-run watchdog uses timeout_s: 5 (runner exited in 1s; would be ~30s with router.timeout_s)
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] runner.sh does not reference ZBUILD_RELEASE_TIMEOUT (removed in #1801)
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] runner.sh does not reference _TPL_STAGE_ROUTER_TIMEOUT (router.timeout_s removed from always-run watchdog in #1801)
  [38;2;248;113;113m[1m1 of 22 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
