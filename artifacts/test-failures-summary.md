# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.DPn1DO/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    [2mexpected: 1, got: [0m
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.DPn1DO/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.DPn1DO/tests/integration/route-tautology-to-design-test.sh
  [38;2;248;113;113m✗[0m S1: impact leaf dispatched TWICE (initial + one replay after rewind)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m S1: cycle.route_back emitted exactly once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S1: pipeline completes after the bounded rewind
    [2mexpected: complete, got: null[0m
  [38;2;248;113;113m✗[0m S1: impact leaf dispatched TWICE (initial + one replay after rewind)
  [38;2;248;113;113m✗[0m S1: cycle.route_back emitted exactly once
  [38;2;248;113;113m✗[0m S1: pipeline completes after the bounded rewind
```
