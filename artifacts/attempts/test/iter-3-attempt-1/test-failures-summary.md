# Test stage summary

- verdict: fail
- passed: 818
- failed: 3
- exit_code: 1

## Failing files

- tests/integration/run-timed-out-test.sh — ✗ [#1944/SPEC-1] P2: run ended within max_run_s+buffer — watchdog is a global wall-clock timer not a per-stage reset — elapsed 18s > 10s — per-stage reset timer would fire at ~11s; global watchdog fires at ~6s; expected ≤ 10s
- tests/integration/runner-release-exit-paths-test.sh — ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
- tests/unit/runner-abort-banner-stderr-test.sh — ✗ [B3] the abort trap's first statement restores stderr — expected: _runner_restore_stderr, got: trap ':' INT TERM

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m [B3] the abort trap's first statement restores stderr
    [2mexpected: _runner_restore_stderr, got: trap ':' INT TERM[0m
  [38;2;248;113;113m✗[0m [#1944/SPEC-1] P2: run ended within max_run_s+buffer — watchdog is a global wall-clock timer not a per-stage reset
    [2melapsed 18s > 10s — per-stage reset timer would fire at ~11s; global watchdog fires at ~6s; expected ≤ 10s[0m
  [38;2;248;113;113m✗[0m [SPEC-5] cleanup dispatched with scope=release for: intake build
    [2mno release from: intake build | marker= [0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.DLpGR0/tests/unit/runner-abort-banner-stderr-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.DLpGR0/tests/integration/run-timed-out-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.DLpGR0/tests/integration/runner-release-exit-paths-test.sh
  [38;2;74;222;128m✓[0m [B4] stderr is saved (line 2745) before the EXIT trap is set (line 2746)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 4 tests failed[0m
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: pipeline status=timed_out
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path
  [38;2;248;113;113m[1m1 of 16 tests failed[0m
  [38;2;74;222;128m✓[0m [SPEC-6] the blocked hook does not outlive the run
  [38;2;0;212;255mSPEC-6b: a hook child that ignores TERM does not outlive the run[0m
  [38;2;74;222;128m✓[0m [SPEC-6b] a hook child that ignores TERM does not outlive the run
  [38;2;248;113;113m[1m1 of 19 tests failed[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
