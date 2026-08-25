# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.zrAGAn/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
  [38;2;248;113;113m✗[0m [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.zrAGAn/tests/integration/build-test-cycle-fallthrough-to-review-test.sh
  [38;2;248;113;113m✗[0m A: pipeline_status=failed (NOT complete — the actual bug fix)
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m A: cycle.unconverged event
  [38;2;248;113;113m✗[0m A: pipeline.end event fires exactly once
    [2mexpected: 1, got: 0[0m
  [38;2;248;113;113m✗[0m A: pipeline.end status
    [2mexpected status=failed in pipeline.end event[0m
  [38;2;248;113;113m✗[0m B: rc=2 plateau → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m B: cycle.unconverged reason=plateau
  [38;2;248;113;113m✗[0m A: pipeline_status=failed (NOT complete — the actual bug fix)
  [38;2;248;113;113m✗[0m A: cycle.unconverged event
  [38;2;248;113;113m✗[0m A: pipeline.end event fires exactly once
  [38;2;248;113;113m✗[0m A: pipeline.end status
  [38;2;248;113;113m✗[0m B: rc=2 plateau → pipeline_status=failed
  [38;2;248;113;113m✗[0m B: cycle.unconverged reason=plateau
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.zrAGAn/tests/integration/route-tautology-to-design-test.sh
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
