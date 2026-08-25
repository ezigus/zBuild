# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.xMX7U6/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    [2mexpected: 1, got: [0m
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.xMX7U6/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=1 → cycle.unconverged emitted once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m rc=2 → cycle.unconverged emitted once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=1 → cycle.unconverged emitted once
  [38;2;248;113;113m✗[0m rc=2 → cycle.unconverged emitted once
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.xMX7U6/tests/integration/route-tautology-to-design-test.sh
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S2: impact dispatched TWICE then budget spent (no third design pass)
    [2mexpected: 2, got: 0[0m
  [38;2;248;113;113m✗[0m S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
  [38;2;248;113;113m✗[0m S2: impact dispatched TWICE then budget spent (no third design pass)
  [38;2;248;113;113m✗[0m S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)
```
