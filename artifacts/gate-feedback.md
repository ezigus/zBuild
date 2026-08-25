# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 363/364 passed (5 skipped)
integration: 232/234 passed (1 skipped)
e2e: 8/8 passed (1 skipped)
golden: 1/1 passed

─── Mutation test results ──────────────────────────────
  PASS  atomic-state-mutations.md  (caught: rc=3)
  PASS  cache.md  (caught: rc=1)
  PASS  cleanup-worktree-age-guard.md  (caught: rc=2)
  PASS  cleanup-worktree-dirty-guard.md  (caught: rc=2)
  PASS  detect-platforms.md  (caught: rc=11)
  PASS  event-bus-ansi-strip.md  (caught: rc=4)
  PASS  event-bus.md  (caught: rc=3)
  INFRA memory.md  (patch failed after retries)
  PASS  orch.md  (caught: rc=1)
  PASS  output-destinations.md  (caught: rc=1)
  PASS  pipeline-contracts.md  (caught: rc=2)
  PASS  pipeline-dispatch-arg-mutations.md  (caught: rc=4)
  PASS  pipeline-dispatch-failopen-mutations.md  (caught: rc=7)
  PASS  pipeline-dispatch-mutations.md  (caught: rc=9)
  PASS  pipeline-dispatch-prefix-mutations.md  (caught: rc=1)
  PASS  pipeline-dispatch-selfsource-mutations.md  (caught: rc=1)
  PASS  pipeline-resolver.md  (caught: rc=1)
  PASS  rc-semantics.md  (caught: rc=1)
  PASS  registry-role-resolution.md  (caught: rc=1)
  PASS  registry-validate-manifest-mutations.md  (caught: rc=1)
  PASS  resume-recommendation-mutations.md  (caught: rc=1)
  PASS  router-route-mutations.md  (caught: rc=30)
  PASS  runner-fail-closed-mutations.md  (caught: rc=1)
  PASS  scope-redaction-mutations.md  (caught: rc=3)
mutation-infra: 1 non-fatal (worktree/patch contention; excluded from score — #1184)
mutation: 23/23 passed
lint: 1/1 passed
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/unit/route-back-budget-config-test.sh

  route_back budget default 2 + config override (#1217)

  ✓ S4: default budget (unset) → 1 route_back (=2 total passes)
  ✓ S4: ZBUILD_ROUTE_BACK_BUDGET=1 → 0 route_backs
  ✓ S4: ZBUILD_ROUTE_BACK_BUDGET=3 → 2 route_backs
  ✓ S4: budget=5 + per-edge max=1 → edge cap wins (1 route_back)
  ✗ S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)
    expected: 1, got: 0
  ✓ S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')


  1 of 6 tests failed

  ✗ S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)

integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/integration/build-test-cycle-fallthrough-to-review-test.sh

  cycle fall-through → review → pipeline=failed (#527)

  ✓ A: pipeline_status=failed (NOT complete — the actual bug fix)
  ✓ A: cycle.unconverged event emitted with reason=max_iterations
  ✓ A: pipeline.end event fires exactly once
  ✓ A: pipeline.end status=failed
  ✗ B: rc=2 plateau → pipeline_status=failed
    expected: failed, got: null
  ✗ B: cycle.unconverged reason=plateau
    missing
  ✗ C: rc=3 divergence → pipeline_status=failed
    expected: failed, got: null
  ✗ C: cycle.unconverged reason=divergence
    missing
  ✓ D: positive control — rc=0 converged + approve → status=complete
  ✓ D: cycle.unconverged NOT emitted on converged path
  ✓ E: rc=4 config_invalid → status=interrupted
  ✓ E: review SKIPPED on halt path
  ✓ F: rc=5 blocked (#528) → status=interrupted
  ✓ F: review SKIPPED on rc=5 halt path
  ✓ G: rc=130 aborted → status=interrupted


  4 of 15 tests failed

  ✗ B: rc=2 plateau → pipeline_status=failed
  ✗ B: cycle.unconverged reason=plateau
  ✗ C: rc=3 divergence → pipeline_status=failed
  ✗ C: cycle.unconverged reason=divergence

integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824211617-31534/scratch/test/zbuild-test-stage.enNZQ7/tests/integration/route-tautology-to-design-test.sh

  route_back plumbing → design_verify_cycle (retained/dormant; #1219, #1583)

  ✗ S1: impact leaf dispatched TWICE (initial + one replay after rewind)
    expected: 2, got: 0
  ✗ S1: cycle.route_back emitted exactly once
    expected: 1, got: 0
  ✗ S1: pipeline completes after the bounded rewind
    expected: complete, got: null
  ✗ S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
    expected: 1, got: 0
  ✗ S2: impact dispatched TWICE then budget spent (no third design pass)
    expected: 2, got: 0
  ✗ S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)
    expected: failed, got: null


  6 of 6 tests failed

  ✗ S1: impact leaf dispatched TWICE (initial + one replay after rewind)
  ✗ S1: cycle.route_back emitted exactly once
  ✗ S1: pipeline completes after the bounded rewind
  ✗ S2: cycle.route_back emitted exactly once (budget=2 → one jump, no ping-pong)
  ✗ S2: impact dispatched TWICE then budget spent (no third design pass)
  ✗ S2: budget spent → fallback rc=8 → status=failed (clean hard-fail)


total: 628/631 passed (7 skipped)
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-1/SPEC-2/SPEC-3 tautological (pass at baseline) — re-author the assertions
- failures:
    - tautology:SPEC-1
    - tautology:SPEC-2
    - tautology:SPEC-3

