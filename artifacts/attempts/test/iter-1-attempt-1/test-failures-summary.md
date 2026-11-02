# Test stage summary

- verdict: fail
- passed: 829
- failed: 12
- exit_code: 1

## Failing files

- tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh — ✗ T4: both inner cycle.start at iter=1 (RESET, not 4) — expected: 1, got: 1
- tests/integration/cycle-member-dispatch-events-test.sh — ✗ inner_cycle dispatch.complete verdict=blocking_member_failure (propagated) — expected: blocking_member_failure, got: fail
- tests/integration/from-stage-rehydrate-test.sh — ✗ [#1805/SPEC-3] intake emits no stage.start when skipped via --from-stage — expected: 0, got: 0
- tests/integration/nested-loop-rounds-build-test.sh — ✗ [L3] the outer loop goes round: design runs again — expected: 2, got: 1
- tests/integration/nested-loop-rounds-test.sh — ✗ [L2] design starts again at round 1 in the second outer round — expected: 2, got: 1
- tests/integration/resume-entry-points-test.sh — ✗ [#1805/SPEC-13] cyclic stage 'cycled' dispatched — pipeline containing cyclic stage ran in resume-entry-points test — expected >0, got: 0
- tests/integration/resume-loop-state-test.sh — ✗ [#1805/SPEC-7] no cycle.iteration.complete for iter=1 (iter-1 was already done before resume) — expected: 0, got: 0
- tests/integration/resume-rehydrate-test.sh — ✗ [#1805/SPEC-1] intake emits no stage.start (complete stage skipped) — expected: 0, got: 0
- tests/integration/run-timed-out-test.sh — ✗ [#1944/SPEC-1] P2: run ended within max_run_s+buffer — watchdog is a global wall-clock timer not a per-stage reset
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
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/unit/stage-retry-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/cycle-member-dispatch-events-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/from-stage-rehydrate-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/nested-loop-rounds-build-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/nested-loop-rounds-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/resume-entry-points-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/resume-loop-state-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/resume-rehydrate-test.sh
integration: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.3cM6rZ/tests/integration/run-timed-out-test.sh
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
  [38;2;0;212;255m[#1805/SPEC-13] from-stage-rehydrate test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m [#1805/SPEC-13] from-stage-rehydrate test uses a cyclic fixture (type: cycle)
  [38;2;74;222;128m✓[0m [#1805/SPEC-13] cyclic fixture pipeline ran in from-stage-rehydrate test (intake dispatched)
  [38;2;248;113;113m[1m1 of 10 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-3] intake emits no stage.start when skipped via --from-stage
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
  [38;2;248;113;113m✗[0m [#1805/SPEC-13] cyclic stage 'cycled' dispatched — pipeline containing cyclic stage ran in resume-entry-points test
    [2mexpected >0, got: 0
0[0m
  [38;2;248;113;113m[1m1 of 6 tests failed[0m
  [38;2;0;212;255m[#1805/SPEC-13] resume-loop-state test uses a fixture containing a cyclic stage[0m
  [38;2;74;222;128m✓[0m [#1805/SPEC-13] cycle fixture used by resume-loop-state test has type: cycle
  [38;2;74;222;128m✓[0m [#1805/SPEC-13] resume-loop-state ran the cyclic pipeline (cycle_dispatch_stage was invoked)
  [38;2;248;113;113m[1m1 of 4 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-7] no cycle.iteration.complete for iter=1 (iter-1 was already done before resume)
  [38;2;248;113;113m[1m5 of 24 tests failed[0m
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] intake emits no stage.start (complete stage skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 2 (auto-resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m [#1805/SPEC-1] path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)
  [38;2;248;113;113m✗[0m 

[truncated]

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — SPEC-1/SPEC-3/SPEC-7/tests/integration/resume-rehydrate-test.sh/tests/integration/resume-rehydrate-test.sh: its test does not pass on the new code — the code or the test is wrong
