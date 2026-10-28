# Test stage summary

- verdict: fail
- passed: 820
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/run-timed-out-test.sh — ✗ [#1944/SPEC-1] P2: fast-two never started — watchdog fired in idle window between dispatches — fast-two sentinel found at /home/runner/work/_temp/zbuild-state/scratch/test/run-timed-out.DIwXFB/fast-two-started — watchdog did not fire before fast-two was dispatched

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [#1944/SPEC-1] P2: fast-two never started — watchdog fired in idle window between dispatches
    [2mfast-two sentinel found at /home/runner/work/_temp/zbuild-state/scratch/test/run-timed-out.DIwXFB/fast-two-started — watchdog did not fire before fast-two was dispatched[0m
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.b98p5u/tests/integration/run-timed-out-test.sh
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: pipeline status=timed_out
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
