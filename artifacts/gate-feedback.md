# Gate Aggregator Feedback

The build_test_cycle did not converge: 1 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 360/363 passed (5 skipped)
integration: 233/234 passed (1 skipped)
e2e: 8/8 passed (1 skipped)
golden: 0/1 passed

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
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/event-schema-emitted-coverage-test.sh

  event-schema emitted-⊆-composed known types (all plugins + core)

  ✗ emitted type 'router.permissions.scratch_fallback' is in the composed known set
    not in config/event-schema.json nor any manifest's provides.events
  ✓ [SPEC-1717-1] every plugin-emitted event is declared in that plugin's own manifest
  ✓ [SPEC-1717-2] config/event-schema.json carries no plugin-owned namespace
  ✓ [SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself
  ✓ [SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types


  1 of 5 tests failed

  ✗ emitted type 'router.permissions.scratch_fallback' is in the composed known set

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/route-back-budget-config-test.sh

  route_back budget default 2 + config override (#1217)

  ✓ S4: default budget (unset) → 1 route_back (=2 total passes)
  ✓ S4: ZBUILD_ROUTE_BACK_BUDGET=1 → 0 route_backs
  ✓ S4: ZBUILD_ROUTE_BACK_BUDGET=3 → 2 route_backs
  ✓ S4: budget=5 + per-edge max=1 → edge cap wins (1 route_back)
  ✓ S4: budget=2 + per-edge max=5 → global ceiling wins (1 route_back)
  ✗ S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')
    expected: 1, got: 


  1 of 6 tests failed

  ✗ S4: ZBUILD_ROUTE_BACK_BUDGET=0 clamps to 1 (warn denom '1', not '0')

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/unit/runner-cycle-rc-action-mapping-test.sh

  runner cycle rc → (action, status) mapping (#527)

  ✓ rc=0 → pipeline_status=complete
  ✓ rc=0 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=1 → pipeline_status=failed
  ✓ rc=1 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=2 → pipeline_status=failed
  ✓ rc=2 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=3 → pipeline_status=failed
  ✓ rc=3 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=4 → pipeline_status=interrupted
  ✓ rc=5 → pipeline_status=interrupted
  ✓ rc=8 → pipeline_status=failed
  ✓ rc=130 → pipeline_status=interrupted
  ✓ rc=0 → cycle.unconverged NOT emitted
  ✓ rc=1 → cycle.unconverged emitted once
  ✓ rc=2 → cycle.unconverged emitted once
  ✓ rc=3 → cycle.unconverged emitted once
  ✓ rc=4 → cycle.unconverged NOT emitted
  ✓ rc=5 → cycle.unconverged NOT emitted
  ✓ rc=8 → cycle.unconverged NOT emitted
  ✓ rc=130 → cycle.unconverged NOT emitted
  ✗ [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed
    expected: failed, got: null


  1 of 21 tests failed

  ✗ [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed

integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/integration/route-tautology-to-design-test.sh

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

golden: FAIL /Users/ericziegler/.zbuild/state/runs/20260824192938-55825/scratch/test/zbuild-test-stage.cm72sZ/tests/golden/golden-contracts-test.sh

  golden contracts — assert_golden harness (E.1 seed set)

  ✓ G1: redaction.applied event shape matches golden
  ✓ G2: init_state JSON shape matches golden
  ✓ G3: CLI dry-run output matches golden
  ✓ G4: canonical plugin lifecycle event types match golden
  ✓ [SPEC-6] plugin.init/finalize complete events absent from event schema
  ✓ [SPEC-7] plugin lifecycle golden has exactly 2 event types (run + cleanup)
mock-response
  [golden] DIFF for router-success-event-sequence:
2a3
> router.permissions.scratch_fallback
  ✗ G5: router success event sequence
    assert_golden returned 1
  ✓ G5b: model.route event data keys match golden


  1 of 8 tests failed

  ✗ G5: router success event sequence


total: 625/630 passed (7 skipped)
```

