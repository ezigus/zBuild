# Test stage summary

- failed: tests/integration/resume-rehydrate-test.sh
- verdict: fail
- passed: 886
- failed: 1
- exit_code: 1

## Failing files

- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/DSFRSH-1] fresh run (--no-resume) dispatches all stages: cycle stage cyc emits cycle.start (all stages dispatched from stage 1; none skipped due to prior state) — expected >0, got: 0 (and 3 more failing checks in this file)

## Failing lines (extracted)

```
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.sQ3HtM/tests/integration/resume-rehydrate-test.sh
  [38;2;74;222;128m✓[0m [#1805/DSCYCL-1] resume-rehydrate (DSRHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle
  [38;2;74;222;128m✓[0m resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m2 of 49 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/DSFRSH-1] fresh run (--no-resume) dispatches all stages: cycle stage cyc emits cycle.start (all stages dispatched from stage 1; none skipped due to prior state)
  [38;2;248;113;113m✗[0m [#1805/DSFRSH-2] fresh run dispatches all stages: cycle stage cyc emits cycle.start (dispatch-unit skip guard conditional on resume_mode; does not activate for fresh runs)
    [2mexpected >0, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
