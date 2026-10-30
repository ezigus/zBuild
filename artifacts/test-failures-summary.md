# Test stage summary

- verdict: fail
- passed: 829
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
  [38;2;248;113;113m✗[0m [#1801/SPEC-5] hard-kill path: EXIT trap must dispatch cleanup for intake and build
    [2mexpected intake:release and build:release in marker; got:  ; old code: EXIT trap not invoked on TERM→KILL path[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.QuSfUz/tests/integration/runner-release-exit-paths-test.sh
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] deployed.yaml: release.timeout_s is 30 at stage level
  [38;2;74;222;128m✓[0m [#1801/SPEC-5] deployed.yaml: persist.timeout_s is 120 at stage level
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 26 tests failed[0m
```

## The checks of this run
- the acceptance check failed: the acceptance check failed — core/pipeline/runner.sh is not changed by this change — name a file the change touches, or write WIRING: none
