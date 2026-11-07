# Test stage summary

- failed: tests/unit/event-schema-emitted-coverage-test.sh, tests/unit/runner-startup-preflight-test.sh
- verdict: fail
- passed: 881
- failed: 2
- exit_code: 1

## Failing files

- tests/unit/event-schema-emitted-coverage-test.sh — ✗ emitted type 'cycle.state.write.failed' is in the composed known set — not in config/event-schema.json nor any manifest's provides.events (and 1 more failing check in this file)
- tests/unit/runner-startup-preflight-test.sh — ✗ [SPEC-5] call-site: _runner_startup_preflight_gate is invoked from main() — expected: 1, got: 0 (and 1 more failing check in this file)

## Failing lines (extracted)

```
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.FaHOTv/tests/unit/event-schema-emitted-coverage-test.sh
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.FaHOTv/tests/unit/runner-startup-preflight-test.sh
  [38;2;74;222;128m✓[0m [#1951/R1] … and an engine namespace is not flagged
  [38;2;74;222;128m✓[0m [#1951/SPEC-4] a test file that is missing is not taken as clean
  [38;2;74;222;128m✓[0m [#1951/SPEC-6] the hardcoded plugin-namespace guard variable is absent from this file
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 25 tests failed[0m
  [38;2;248;113;113m✗[0m emitted type 'cycle.state.write.failed' is in the composed known set
    [2mexpected: 1, got: 0[0m
  [38;2;74;222;128m✓[0m [SPEC-6] off mode: rc=0
  [38;2;74;222;128m✓[0m [SPEC-6] off mode: no output
  [38;2;248;113;113m[1m1 of 11 tests failed[0m
  [38;2;248;113;113m✗[0m [SPEC-5] call-site: _runner_startup_preflight_gate is invoked from main()
```

## The checks of this run
- the shape floor failed: missing_floor_files
