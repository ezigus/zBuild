# Test stage summary

- verdict: fail
- passed: 74
- failed: 3
- exit_code: 1

## Failing lines (extracted)

```
unit: FAIL tests/integration/resume-rehydrate-test.sh
unit: FAIL tests/integration/write-boundary-revert-test.sh
unit: FAIL tests/unit/stage-retry-test.sh
  [38;2;0;212;255mresume-rehydrate test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m [#1805/CYCL-1] resume-rehydrate (RHYD-1/RHYD-2/BNDY-1) fixture (artifact-snapshot-coverage) contains type: cycle
  [38;2;74;222;128m✓[0m resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m1 of 46 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/FRSH-2] fresh run dispatches cycled (inner member of cyc; every stage emits stage.start, not just intake)
    [2mexpected: broken, got: unusable[0m
  [38;2;74;222;128m✓[0m [D7] the files are put back
  [38;2;248;113;113m[1m2 of 20 tests failed[0m
  [38;2;248;113;113m✗[0m [D7] the first offence was retried
  [38;2;248;113;113m✗[0m [D7] the retry's offence halts
  [38;2;248;113;113m✗[0m [R7] it names the stage
  [38;2;248;113;113m✗[0m [R7] ...the outcome the try ended on
  [38;2;248;113;113m✗[0m [R7] ...which try comes next
  [38;2;248;113;113m✗[0m [R7] ...of how many
  [38;2;248;113;113m✗[0m [R8] a stage run from a work unit is run again too → 2 runs
  [38;2;248;113;113m✗[0m [R11] each try is told its number
    [2mexpected >0, got: 0[0m
  [38;2;248;113;113m✗[0m [R1] timed_out with progress, no retry: in the template → 2 runs
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m [R1] the retry that passes is what the dispatch reports
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [R2] retry: 2 → 3 runs
    [2mexpected: 3, got: 1[0m
  [38;2;248;113;113m✗[0m [R2] every word that means 'did not finish' is retried
  [38;2;248;113;113m✗[0m [R4] a try that changed nothing is not run again
  [38;2;248;113;113m✗[0m [R5] retry: 9 is capped at 5 → 6 runs
    [2mexpected: 6, got: 1[0m
  [38;2;248;113;113m✗[0m [R5] retry: lots → the default 1 → 2 runs
  [38;2;248;113;113m✗[0m [R6] ZBUILD_DISPOSITION_REDISPATCH=4 changes nothing → 2 runs
  [38;2;248;113;113m✗[0m [R7] one stage.retry for the one retry
    [2mexpected: 1, got: 0[0m
    [2mexpected: twice, got: [0m
    [2mexpected: timed_out, got: [0m
    [2mexpected: 2, got: [0m
    [2mexpected: 3, got: [0m
    [2mexpected: 1 2 3 , got: none [0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
