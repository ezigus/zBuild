# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/event-schema-emitted-coverage-test.sh
  [38;2;248;113;113m✗[0m emitted type 'router.permissions.scratch_fallback' is in the composed known set
  [38;2;248;113;113m✗[0m emitted type 'router.permissions.scratch_fallback' is in the composed known set
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    [2mexpected: 1, got: [0m
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/integration/route-tautology-to-design-test.sh
  [38;2;248;113;113m✗[0m S1: impact leaf dispatched TWICE (initial + one replay after rewind)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m S1: cycle.route_back emitted exactly once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S1: pipeline completes after the bounded rewind
    [2mexpected: complete, got: null[0m
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S2: impact dispatched TWICE then budget spent (no third design pass)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m S1: impact leaf dispatched TWICE (initial + one replay after rewind)
  [38;2;248;113;113m✗[0m S1: cycle.route_back emitted exactly once
  [38;2;248;113;113m✗[0m S1: pipeline completes after the bounded rewind
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
  [38;2;248;113;113m✗[0m S2: impact dispatched TWICE then budget spent (no third design pass)
  [38;2;248;113;113m✗[0m S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)
golden: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/golden/golden-contracts-test.sh
  [38;2;248;113;113m✗[0m G5: router success event sequence
  [38;2;248;113;113m✗[0m G5: router success event sequence
```
