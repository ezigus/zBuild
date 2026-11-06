# Test stage summary

- failed: tests/integration/resume-loop-state-test.sh, tests/integration/resume-rehydrate-test.sh
- verdict: fail
- passed: 880
- failed: 2
- exit_code: 1

## Failing files

- tests/integration/resume-loop-state-test.sh — ✗ [#1805/CMBR-1] no stage.start for 'build' in iter 2 (complete member skipped on resume within interrupted iter) — expected: 0, got: 1 (and 1 more failing check in this file)
- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/FRSH-2] fresh run cycle member emits exactly one stage.start per iteration (not duplicated by missing _ZBUILD_RESUME_ACTIVE guard in _cycle_dispatch) — expected: 1, got: 0 (and 1 more failing check in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Lz4HOx/tests/integration/resume-loop-state-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.Lz4HOx/tests/integration/resume-rehydrate-test.sh
  [38;2;0;212;255mresume-loop-state test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m cycle fixture used by resume-loop-state test has type: cycle
  [38;2;74;222;128m✓[0m resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 8 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/CMBR-1] no stage.start for 'build' in iter 2 (complete member skipped on resume within interrupted iter)
  [38;2;0;212;255mresume-rehydrate test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m [#1805/CYCL-1] resume-rehydrate (RHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle
  [38;2;74;222;128m✓[0m resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)
  [38;2;248;113;113m[1m1 of 46 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/FRSH-2] fresh run cycle member emits exactly one stage.start per iteration (not duplicated by missing _ZBUILD_RESUME_ACTIVE guard in _cycle_dispatch)
    [2mexpected: 0, got: 1[0m
    [2mexpected: 1, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — CMBR-1: its test does not pass on the new code — the code or the test is wrong
