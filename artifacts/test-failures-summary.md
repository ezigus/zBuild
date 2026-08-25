# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.Fztf5L/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    [2mexpected: 1, got: [0m
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.Fztf5L/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m rc=4 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=4 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.Fztf5L/tests/integration/build-test-cycle-fallthrough-to-review-test.sh
  [38;2;248;113;113m✗[0m A: pipeline_status=failed (NOT complete — the actual bug fix)
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m A: cycle.unconverged event
  [38;2;248;113;113m✗[0m A: pipeline.end event fires exactly once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m A: pipeline.end status
    [2mexpected status=failed in pipeline.end event[0m
  [38;2;248;113;113m✗[0m A: pipeline_status=failed (NOT complete — the actual bug fix)
  [38;2;248;113;113m✗[0m A: cycle.unconverged event
  [38;2;248;113;113m✗[0m A: pipeline.end event fires exactly once
  [38;2;248;113;113m✗[0m A: pipeline.end status
```
