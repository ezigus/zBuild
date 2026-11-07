# Test stage summary

- failed: tests/integration/run-timed-out-test.sh, tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124)
- verdict: fail
- passed: 880
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/run-timed-out-test.sh — ✗ [#1944/SPEC-1] P2: run ended within max_run_s+buffer — watchdog is a global wall-clock timer not a per-stage reset — elapsed 22s > 17s — a global watchdog ends the run at ~12s; a per-stage reset at ~20s+ (and 1 more failing check in this file)
- tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124) — timed out before finishing

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.P4pz23/tests/integration/run-timed-out-test.sh
integration: TIMEOUT /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.P4pz23/tests/integration/sigterm-aborts-pipeline-test.sh (exceeded 480s, rc=124)
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: pipeline status=timed_out
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: release (always_run) stage ran on timed-out exit path
  [38;2;74;222;128m✓[0m [#1944/SPEC-1] P4: persist (always_run) stage ran on timed-out exit path
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 17 tests failed[0m
  [38;2;248;113;113m✗[0m [#1944/SPEC-1] P2: run ended within max_run_s+buffer — watchdog is a global wall-clock timer not a per-stage reset
--- output below ran against a process being killed at its time bound;
--- any assertion failures in it are UNTRUSTWORTHY (#1613) ---
[38;2;0;212;255m[1m  sigterm-aborts-pipeline — kill -TERM halts pipeline (#686)[0m
[2m  ══════════════════════════════════════════[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
