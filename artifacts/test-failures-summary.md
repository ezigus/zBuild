# Test failures summary

## Failing lines (extracted)

```
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/event-schema-emitted-coverage-test.sh
  [38;2;248;113;113m✗[0m emitted type 'router.permissions.scratch_fallback' is in the composed known set
  [38;2;248;113;113m✗[0m emitted type 'router.permissions.scratch_fallback' is in the composed known set
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/route-back-budget-config-test.sh
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    [2mexpected: 1, got: [0m
  [38;2;248;113;113m✗[0m S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/write-boundary-sweep-test.sh
  [38;2;248;113;113m✗[0m [SPEC-4e] a zbuild_engine_tmpdir caller does not source helpers.sh
  [38;2;248;113;113m✗[0m [SPEC-4e] a zbuild_engine_tmpdir caller does not source helpers.sh
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/route-missing-include-test.sh
  [38;2;248;113;113m✗[0m [SPEC-5] a healthy tree loads cleanly (rc=0)
    [2mexpected: 0, got: 1[0m
  [38;2;248;113;113m✗[0m [SPEC-5] the caller continues past a healthy load
  [38;2;248;113;113m✗[0m [SPEC-5] a healthy tree loads cleanly (rc=0)
  [38;2;248;113;113m✗[0m [SPEC-5] the caller continues past a healthy load
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/runner-cycle-rc-action-mapping-test.sh
  [38;2;248;113;113m✗[0m rc=3 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=3 → intake dispatched (stage_statuses.intake=complete) [#842]
    [2mexpected: complete, got: absent[0m
  [38;2;248;113;113m✗[0m rc=4 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
    [2mexpected: interrupted, got: null[0m
  [38;2;248;113;113m✗[0m rc=3 → pipeline_status=failed
  [38;2;248;113;113m✗[0m rc=3 → intake dispatched (stage_statuses.intake=complete) [#842]
  [38;2;248;113;113m✗[0m rc=4 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=5 → pipeline_status=interrupted
  [38;2;248;113;113m✗[0m rc=8 → pipeline_status=failed
  [38;2;248;113;113m✗[0m rc=130 → pipeline_status=interrupted
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/integration/build-test-cycle-fallthrough-to-review-test.sh
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
  [38;2;248;113;113m✗[0m C: rc=3 divergence → pipeline_status=failed
    [2mexpected: failed, got: null[0m
  [38;2;248;113;113m✗[0m C: cycle.unconverged reason=divergence
  [38;2;248;113;113m✗[0m A: pipeline_status=failed (NOT complete — the actual bug fix)
  [38;2;248;113;113m✗[0m A: cycle.unconverged event
  [38;2;248;113;113m✗[0m A: pipeline.end event fires exactly once
  [38;2;248;113;113m✗[0m A: pipeline.end status
  [38;2;248;113;113m✗[0m B: rc=2 plateau → pipeline_status=failed
  [38;2;248;113;113m✗[0m B: cycle.unconverged reason=plateau
  [38;2;248;113;113m✗[0m C: rc=3 divergence → pipeline_status=failed
  [38;2;248;113;113m✗[0m C: cycle.unconverged reason=divergence
integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/integration/route-tautology-to-design-test.sh
  [38;2;248;113;113m✗[0m S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
    [2mexpected: 1, got: 0[0m
```
