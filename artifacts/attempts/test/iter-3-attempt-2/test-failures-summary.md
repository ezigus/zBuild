# Test stage summary

- failed: tests/integration/resume-rehydrate-test.sh
- verdict: fail
- passed: 886
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/DSFRSH-1] fresh run dispatches cycle stage (cyc) — cycle.start emitted (cycle stage not erroneously suppressed by skip guard) — expected >0, got: 0 (and 3 more failing checks in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.pYf59F/tests/integration/resume-rehydrate-test.sh
  [38;2;74;222;128m✓[0m [#1805/DSCYCL-1] resume-rehydrate (DSRHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle
  [38;2;74;222;128m✓[0m resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 51 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/DSFRSH-1] fresh run dispatches cycle stage (cyc) — cycle.start emitted (cycle stage not erroneously suppressed by skip guard)
  [38;2;248;113;113m✗[0m [#1805/DSFRSH-2] fresh run dispatches cycle stage (cyc) — cycle.start emitted (skip guard conditional on resume_mode does not suppress cycle stage on fresh run)
    [2mexpected >0, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
