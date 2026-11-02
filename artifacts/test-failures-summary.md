# Test stage summary

- verdict: fail
- passed: 832
- failed: 9
- exit_code: 1

## Failing files

- tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh — ✗ T4: both inner cycle.start at iter=1 (RESET, not 4) — expected: 1, got: 1
- tests/integration/cycle-member-dispatch-events-test.sh — ✗ inner_cycle dispatch.complete verdict=blocking_member_failure (propagated) — expected: blocking_member_failure, got: fail
- tests/integration/nested-loop-rounds-build-test.sh — ✗ [L3] the outer loop goes round: design runs again — expected: 2, got: 1
- tests/integration/nested-loop-rounds-test.sh — ✗ [L2] design starts again at round 1 in the second outer round — expected: 2, got: 1
- tests/integration/resume-entry-points-test.sh — ✗ cyclic stage 'cycled' dispatched — pipeline containing cyclic stage ran in resume-entry-points test — expected >0, got: 0
- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/SPEC-1] intake emits no stage.start (complete stage skipped) — expected: 0, got: 0
- tests/integration/stop-run-on-fail-test.sh — ✗ [R2] not named: build still runs — expected: 2, got: 1
- tests/integration/write-boundary-revert-test.sh — ✗ [D7] the first offence was retried
- tests/unit/stage-retry-test.sh — ✗ [R1] timed_out with progress, no retry: in the template → 2 runs — expected: 2, got: 1

## Failing lines (extracted)

```
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
  [38;2;248;113;113m✗[0m [R7] it names the stage
    [2mexpected: twice, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...the outcome the try ended on
    [2mexpected: timed_out, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...which try comes next
    [2mexpected: 2, got: [0m
  [38;2;248;113;113m✗[0m [R7] ...of how many
    [2mexpected: 3, got: [0m
  [38;2;248;113;113m✗[0m [R8] a stage run from a work unit is run again too → 2 runs
  [38;2;248;113;113m✗[0m [R11] each try is told its number
    [2mexpected: 1 2 3 , got: none [0m
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/unit/stage-retry-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/cycle-member-dispatch-events-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/nested-loop-rounds-build-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/nested-loop-rounds-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/resume-entry-points-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/resume-rehydrate-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/stop-run-on-fail-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.zhis5x/tests/integration/write-boundary-revert-test.sh
  [38;2;248;113;113m✗[0m T4: both inner cycle.start at iter=1 (RESET, not 4)
  [38;2;248;113;113m✗[0m T5: inner cycle.complete emitted twice
  [38;2;248;113;113m✗[0m T7: inner cycle.iteration.complete emitted 4 times (2 iter × 2 outer iter)
  [38;2;248;113;113m✗[0m T8: inner iteration counts: 2 of iter=1, 2 of iter=2 (proves reset)
  [38;2;248;113;113m✗[0m T9: inner history file contains 2 rows (truncated on outer iter 2 entry)
  [38;2;248;113;113m✗[0m T10: inner history rows have iter=1 and iter=2 only (reset on outer iter 2)
    [2mexpected: 1 failed blocking_member_failure, got: 1 failed design_timeout_exhausted[0m
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 24 tests failed[0m
  [38;2;248;113;113m✗[0m inner_cycle dispatch.complete verdict=blocking_member_failure (propagated)
  [38;2;248;113;113m✗[0m review NOT dispatched after a failing inner cycle (#1208 halt, no rescue)
  [38;2;248;113;113m✗[0m outer cycle halts rc=1, outcome failed, reason blocking_member_failure (propagated)
  [38;2;74;222;128m✓[0m [L7] ...the run stops (rc=1, failed)
  [38;2;74;222;128m✓[0m [L7] ...naming what the halting member said
  [38;2;248;113;113m[1m2 of 8 tests failed[0m
  [38;2;248;113;113m✗[0m [L3] the outer loop goes round: design runs again
  [38;2;248;113;113m✗[0m [L3] the build loop starts again at round 1
  [38;2;248;113;113m[1m4 of 11 tests failed[0m
  [38;2;248;113;113m✗[0m [L2] design starts again at round 1 in the second outer round
  [38;2;248;113;113m✗[0m [L4] the outer loop converges in round 2
  [38;2;248;113;113m✗[0m [L4] design started at round 1 in both outer rounds
  [38;2;248;113;113m✗[0m [L4] build ran once, in round 2
  [38;2;248;113;113m✗[0m cyclic stage 'cycled' dispatched — pipeline containing cyclic stage ran in resume-entry-points test
    [2mexpected >0, got: 0
0[0m
  [38;2;248;113;113m[1m1 of 6 tests failed[0m
  [38;2;248;113;113m[1m5 of 28 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] intake emits no stage.start (complete stage skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 2 (auto-resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-12] fresh run dispatches cycled sub-stage (cycle ran; no stage skipped)
  [38;2;248;113;113m✗[0m resume-rehydrate: pipeline with cyclic fixture was actually run (cycled dispatched)
  [38;2;74;222;128m✓[0m [R7] ...the run converges
  [38;2;74;222;128m✓[0m [R8] the review fails twice: the run stops after the second
  [38;2;74;222;128m✓[0m [R8] ...the run ends failed
  [38;2;248;113;113m[1m1 of 25 tests failed[0m
  [38;2;248;113;113m✗[0m [R2] not named: build still runs
    [2mexpected: broken, got: unusable[0m
  [38;2;74;222;128m✓[0m [D7] the files are put back
  [38;2;248;113;113m[1m2 of 20 tests failed[0m
  [38;2;248;113;113m✗[0m [D7] the first offence was retried
  [38;2;248;113;113m✗[0m [D7] the retry's offence halts
    [2mexpected: 1, got: 1
    [2mexpected: 4, got: 2[0m
    [2mexpected: 2 1
    [2mexpected: 2, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-1/tests/integration/resume-rehydrate-test.sh: its test does not pass on the new code — the code or the test is wrong
