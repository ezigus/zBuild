# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/unit/readout-gates-test.sh
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
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/build-test-cycle-targeted-rerun-test.sh
  [38;2;248;113;113m✗[0m T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
    [2mexpected: targeted, got: ?[0m
  [38;2;248;113;113m✗[0m T3: iter-3 (gate) runs full suite
    [2mexpected: full, got: ?[0m
  [38;2;248;113;113m✗[0m T1: iter-2 test stage runs run_mode=targeted (red-set engaged)
  [38;2;248;113;113m✗[0m T3: iter-3 (gate) runs full suite
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/test-plugin-stage-io-banner-visible-test.sh
  [38;2;248;113;113m✗[0m test_cmd did not produce marker; got: null
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/tests/integration/test-plugin-tmpdir-cleanup-test.sh
  [38;2;248;113;113m✗[0m success: artifact written
    [2mexpected: 0, got: null[0m
  [38;2;248;113;113m✗[0m success: artifact written
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.KrOd8W/plugins/tool/test/tests/test-test.sh
  [38;2;0;212;255mT13. _test_extract_failing_files extracts FAIL paths[0m
  [38;2;74;222;128m✓[0m T13b: empty output when no FAIL lines
  [38;2;248;113;113m✗[0m [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir
    [2mexpected: 0, got: 0
  [38;2;248;113;113m✗[0m [SPEC-9] _test_write_result does not construct artifact paths from artifact_dir
```
