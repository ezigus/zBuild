# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/unit/test-plugin-result-write-fallback-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/unit/readout-gates-test.sh
  [38;2;248;113;113m✗[0m [L1] lint pass → verdict=pass
    [2mkey .verdict: expected pass, got: skip[0m
  [38;2;248;113;113m✗[0m [L2] lint fail → verdict=fail
    [2mkey .verdict: expected fail, got: skip[0m
  [38;2;248;113;113m✗[0m [C1] measured pct>=floor → verdict=pass
    [2mkey .verdict: expected pass, got: skip[0m
  [38;2;248;113;113m✗[0m [C2] measured pct<floor → verdict=fail
    [2mkey .verdict: expected fail, got: skip[0m
  [38;2;248;113;113m✗[0m [C3] status below_floor → verdict=fail
    [2mkey .verdict: expected fail, got: skip[0m
  [38;2;248;113;113m✗[0m [C6] recorded floor wins → verdict=fail
    [2mkey .verdict: expected fail, got: skip[0m
  [38;2;248;113;113m✗[0m [C6] recorded floor reported
    [2mkey .floor: expected 50, got: 10[0m
  [38;2;248;113;113m✗[0m [M1] measured N>=floor → verdict=pass
    [2mkey .verdict: expected pass, got: skip[0m
  [38;2;248;113;113m✗[0m [M2] measured N<floor → verdict=fail
    [2mkey .verdict: expected fail, got: skip[0m
  [38;2;248;113;113m✗[0m [M4] default floor 0 → verdict=pass
    [2mkey .verdict: expected pass, got: skip[0m
  [38;2;248;113;113m✗[0m [L1] lint pass → verdict=pass
  [38;2;248;113;113m✗[0m [L2] lint fail → verdict=fail
  [38;2;248;113;113m✗[0m [C1] measured pct>=floor → verdict=pass
  [38;2;248;113;113m✗[0m [C2] measured pct<floor → verdict=fail
  [38;2;248;113;113m✗[0m [C3] status below_floor → verdict=fail
  [38;2;248;113;113m✗[0m [C6] recorded floor wins → verdict=fail
  [38;2;248;113;113m✗[0m [C6] recorded floor reported
  [38;2;248;113;113m✗[0m [M1] measured N>=floor → verdict=pass
  [38;2;248;113;113m✗[0m [M2] measured N<floor → verdict=fail
  [38;2;248;113;113m✗[0m [M4] default floor 0 → verdict=pass
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-fresh-shell-test.sh
  [38;2;248;113;113m✗[0m subshell exit_code is 0 (all ZBUILD_* unset AND fd 3 closed)
    [2mexpected: 0, got: null[0m
  [38;2;248;113;113m✗[0m test_output should contain 'OK: fresh shell', got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-runs-against-committed-head-test.sh
  [38;2;248;113;113m✗[0m test_cmd executed against rsync'd HEAD
  [38;2;248;113;113m✗[0m .exit_code is numeric
  [38;2;248;113;113m✗[0m test_cmd executed against rsync'd HEAD
  [38;2;248;113;113m✗[0m .exit_code is numeric
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/build-test-cycle-targeted-rerun-test.sh
  [38;2;248;113;113m✗[0m T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
    [2mexpected: targeted, got: ?[0m
  [38;2;248;113;113m✗[0m T3: iter-3 (gate) runs full suite
    [2mexpected: full, got: ?[0m
  [38;2;248;113;113m✗[0m T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
  [38;2;248;113;113m✗[0m T3: iter-3 (gate) runs full suite
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-stage-io-banner-visible-test.sh
  [38;2;248;113;113m✗[0m test_cmd did not produce marker; got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-tmpdir-cleanup-test.sh
  [38;2;248;113;113m✗[0m success: artifact written
    [2mexpected: 0, got: null[0m
  [38;2;248;113;113m✗[0m success: artifact written
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Q1jER6/tests/integration/test-plugin-summary-format-test.sh
  [38;2;248;113;113m✗[0m jest: passed=108
    [2mexpected: 108, got: null[0m
  [38;2;248;113;113m✗[0m jest: failed=18
    [2mexpected: 18, got: null[0m
  [38;2;248;113;113m✗[0m pytest: passed=42
```
