# Test stage summary

- verdict: fail
- passed: 4
- failed: 7
- exit_code: 1

## Failing lines (extracted)

```
  [38;2;248;113;113m✗[0m T4: both inner cycle.start at iter=1 (RESET, not 4)
    [2mexpected: 1, got: 1
  [38;2;248;113;113m✗[0m T5: inner cycle.complete emitted twice
    [2mexpected: 2, got: 1[0m
  [38;2;248;113;113m✗[0m T7: inner cycle.iteration.complete emitted 4 times (2 iter × 2 outer iter)
    [2mexpected: 4, got: 2[0m
  [38;2;248;113;113m✗[0m T8: inner iteration counts: 2 of iter=1, 2 of iter=2 (proves reset)
    [2mexpected: 2 1
  [38;2;248;113;113m✗[0m T9: inner history file contains 2 rows (truncated on outer iter 2 entry)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m T10: inner history rows have iter=1 and iter=2 only (reset on outer iter 2)
    [2mexpected: 1,2, got: [0m
  [38;2;248;113;113m✗[0m inner_cycle dispatch.complete verdict=blocking_member_failure (propagated)
    [2mexpected: blocking_member_failure, got: fail[0m
  [38;2;248;113;113m✗[0m review NOT dispatched after a failing inner cycle (#1208 halt, no rescue)
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m outer cycle halts rc=1, outcome failed, reason blocking_member_failure (propagated)
    [2mexpected: 1 failed blocking_member_failure, got: 1 failed design_timeout_exhausted[0m
  [38;2;248;113;113m✗[0m [L3] the outer loop goes round: design runs again
  [38;2;248;113;113m✗[0m [L3] the build loop starts again at round 1
  [38;2;248;113;113m✗[0m [L2] design starts again at round 1 in the second outer round
  [38;2;248;113;113m✗[0m [L4] the outer loop converges in round 2
unit: FAIL tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
unit: FAIL tests/integration/cycle-member-dispatch-events-test.sh
unit: FAIL tests/integration/nested-loop-rounds-build-test.sh
unit: FAIL tests/integration/nested-loop-rounds-test.sh
unit: FAIL tests/integration/stop-run-on-fail-test.sh
unit: FAIL tests/integration/write-boundary-revert-test.sh
unit: FAIL tests/unit/stage-retry-test.sh
[2m  ──────────────────────────────────────────[0m
  [38;2;248;113;113m[1m3 of 24 tests failed[0m
  [38;2;74;222;128m✓[0m [L7] ...the run stops (rc=1, failed)
  [38;2;74;222;128m✓[0m [L7] ...naming what the halting member said
  [38;2;248;113;113m[1m2 of 8 tests failed[0m
  [38;2;248;113;113m[1m4 of 11 tests failed[0m
  [38;2;248;113;113m✗[0m [L4] design started at round 1 in both outer rounds
  [38;2;248;113;113m✗[0m [L4] build ran once, in round 2
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
  [38;2;248;113;113m✗[0m [R7] it names the stage
  [38;2;248;113;113m✗[0m [R7] ...the outcome the try ended on
  [38;2;248;113;113m✗[0m [R7] ...which try comes next
  [38;2;248;113;113m✗[0m [R7] ...of how many
  [38;2;248;113;113m✗[0m [R8] a stage run from a work unit is run again too → 2 runs
  [38;2;248;113;113m✗[0m [R11] each try is told its number
  [38;2;0;212;255mouter cycle emits expected events[0m
    [2mexpected: 1, got: 0[0m
```

## The checks of this run
- the shape floor failed: missing_floor_files
- the acceptance check failed: the acceptance check failed — plugins/tool/hydrate/plugin.sh was put back to its old version on its own and every test still passed, so no test checks what this change does to it — add a test that fails without the change to it
