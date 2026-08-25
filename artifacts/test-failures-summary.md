# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/integration/build-test-cycle-fallthrough-to-review-test.sh
  [38;2;248;113;113m✗[0m B: rc=2 plateau → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m B: cycle.unconverged reason=plateau
  [38;2;248;113;113m✗[0m C: rc=3 divergence → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m C: cycle.unconverged reason=divergence
  [38;2;248;113;113m✗[0m B: rc=2 plateau → pipeline_status=failed
  [38;2;248;113;113m✗[0m B: cycle.unconverged reason=plateau
  [38;2;248;113;113m✗[0m C: rc=3 divergence → pipeline_status=failed
  [38;2;248;113;113m✗[0m C: cycle.unconverged reason=divergence
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/integration/route-tautology-to-design-test.sh
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
```
