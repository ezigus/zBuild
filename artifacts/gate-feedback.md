# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 358/363 passed (5 skipped)
integration: 232/234 passed (1 skipped)
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
unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/event-schema-emitted-coverage-test.sh

  event-schema emitted-⊆-composed known types (all plugins + core)

  ✗ emitted type 'router.permissions.scratch_fallback' is in the composed known set
    not in config/event-schema.json nor any manifest's provides.events
  ✓ [SPEC-1717-1] every plugin-emitted event is declared in that plugin's own manifest
  ✓ [SPEC-1717-2] config/event-schema.json carries no plugin-owned namespace
  ✓ [SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself
  ✓ [SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types


  1 of 5 tests failed

  ✗ emitted type 'router.permissions.scratch_fallback' is in the composed known set

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/route-back-budget-config-test.sh

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

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/write-boundary-sweep-test.sh

  write-boundary sweep — SPEC-1/4/5 (#1809, ADR-058 C9)

  ✓ [SPEC-1] core/pipeline/write-boundary.sh exists
  ✓ [SPEC-5] write_boundary_mark with empty state_file does not create a marker
  ✓ [SPEC-5] write_boundary_check with empty state_file returns 0 (no-op)
  ✓ [SPEC-5] write_boundary_check with empty state_file emits no events
  ✓ [SPEC-5] no marker file exists after no-op mark
  ✓ [SPEC-5] write_boundary_check returns 0 on clean dispatch (nothing new in watch)
  ✓ [SPEC-5] no stage.write_boundary.violated event on a clean dispatch
  ✓ [SPEC-1] write_boundary_check returns 1 when a file is written outside allowed areas
  ✓ [SPEC-1] write-boundary-violated marker created in runtime/
  ✓ [SPEC-1] the marker names the offending path
  ✓ [SPEC-1] stage.write_boundary.violated event emitted on violation
  ✓ [SPEC-1] the violation event carries path= naming the offending file
  ✓ [SPEC-4] classifier returns 'declared' for a manifest-declared output path
  ✓ [SPEC-4] classifier returns 'allowed' for a path under state_dir (engine-owned)
  ✓ [SPEC-4] classifier returns 'violation' for a path outside all allowed areas
  ✓ [SPEC-4] 'declared' takes precedence over 'allowed' (correct order)
  ✓ [SPEC-4b] symlinked candidate matches a canonical allow root
  ✓ [SPEC-4c] a directory containing the state dir classifies as allowed
  ✓ [SPEC-4c] a stray directory holding no allowed root is still a violation
  ✓ [SPEC-4d] the engine's own event log classifies as allowed
  ✓ [SPEC-4d] a pinned events JSONL allows its own directory
  ✗ [SPEC-4e] a zbuild_engine_tmpdir caller does not source helpers.sh
    callers missing the source: /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/core/router/permissions.sh 
  ✓ [SPEC-4f] the violation log names the stage
  ✓ [SPEC-4f] the violation log names the offending path
  ✓ [SPEC-4f] no sink file is created when the variable is unset
  ✓ [SPEC-4g] the shipped watch list does not carry a system-temp root
  ✓ [SPEC-4g] the shipped watch list still covers /var/folders/yt/lq39xttx6x790xq4zysp_1_h0000gn/T/zbuild-tier-buf.XXXXXX.8lhRs1drSV/tmp-unit/write-boundary-sweep.hjX5CX/home
  ✓ [SPEC-4g] the shipped watch list still covers /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q


  1 of 28 tests failed

  ✗ [SPEC-4e] a zbuild_engine_tmpdir caller does not source helpers.sh

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/route-missing-include-test.sh

  route.sh base-include guards (#1624)

  ✓ [SPEC-1] a missing include → non-zero exit
  ✓ [SPEC-1] the diagnostic names the missing file
  ✓ [SPEC-1] the diagnostic is zbuild's, not a bare bash error
  ✓ [SPEC-2] a broken include → non-zero exit
  ✓ [SPEC-2] the diagnostic names the broken file
  ✓ [SPEC-2] the diagnostic is zbuild's, not a bare bash error
  ✓ [SPEC-2] bash's parse detail is forwarded, not swallowed
  ✓ [SPEC-3] the caller does not run on past a broken include
  ✓ [SPEC-3] the caller does not run on past a missing include
  ✓ [SPEC-4] all 11 base includes are guarded uniformly
  ✗ [SPEC-5] a healthy tree loads cleanly (rc=0)
    expected: 0, got: 1
  ✗ [SPEC-5] the caller continues past a healthy load
    output missing: CALLER_CONTINUED


  2 of 12 tests failed

  ✗ [SPEC-5] a healthy tree loads cleanly (rc=0)
  ✗ [SPEC-5] the caller continues past a healthy load

unit: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/unit/runner-cycle-rc-action-mapping-test.sh

  runner cycle rc → (action, status) mapping (#527)

  ✓ rc=0 → pipeline_status=complete
  ✓ rc=0 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=1 → pipeline_status=failed
  ✓ rc=1 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✓ rc=2 → pipeline_status=failed
  ✓ rc=2 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✗ rc=3 → pipeline_status=failed
    expected: failed, got: null
  ✗ rc=3 → intake dispatched (stage_statuses.intake=complete) [#842]
    expected: complete, got: absent
  ✗ rc=4 → pipeline_status=interrupted
    expected: interrupted, got: null
  ✗ rc=5 → pipeline_status=interrupted
    expected: interrupted, got: null
  ✗ rc=8 → pipeline_status=failed
    expected: failed, got: null
  ✗ rc=130 → pipeline_status=interrupted
    expected: interrupted, got: null
  ✓ rc=0 → cycle.unconverged NOT emitted
  ✓ rc=1 → cycle.unconverged emitted once
  ✓ rc=2 → cycle.unconverged emitted once
  ✓ rc=3 → cycle.unconverged emitted once
  ✓ rc=4 → cycle.unconverged NOT emitted
  ✓ rc=5 → cycle.unconverged NOT emitted
  ✓ rc=8 → cycle.unconverged NOT emitted
  ✓ rc=130 → cycle.unconverged NOT emitted
  ✓ [SPEC-3] rc=8 (blocking_member_failure) → state-file status=failed


  6 of 21 tests failed

  ✗ rc=3 → pipeline_status=failed
  ✗ rc=3 → intake dispatched (stage_statuses.intake=complete) [#842]
  ✗ rc=4 → pipeline_status=interrupted
  ✗ rc=5 → pipeline_status=interrupted
  ✗ rc=8 → pipeline_status=failed
  ✗ rc=130 → pipeline_status=interrupted

integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/integration/build-test-cycle-fallthrough-to-review-test.sh

  cycle fall-through → review → pipeline=failed (#527)

  ✗ A: pipeline_status=failed (NOT complete — the actual bug fix)
    expected: failed, got: null
  ✗ A: cycle.unconverged event
    missing or wrong reason in /var/folders/yt/lq39xttx6x790xq4zysp_1_h0000gn/T/zbuild-tier-buf.XXXXXX.8lhRs1drSV/tmp-integration/cycle-fallthrough-527.JWfwHg/case-cYcAky/events/events.jsonl
  ✗ A: pipeline.end event fires exactly once
    expected: 1, got: 0
  ✗ A: pipeline.end status
    expected status=failed in pipeline.end event
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


  8 of 15 tests failed

  ✗ A: pipeline_status=failed (NOT complete — the actual bug fix)
  ✗ A: cycle.unconverged event
  ✗ A: pipeline.end event fires exactly once
  ✗ A: pipeline.end status
  ✗ B: rc=2 plateau → pipeline_status=failed
  ✗ B: cycle.unconverged reason=plateau
  ✗ C: rc=3 divergence → pipeline_status=failed
  ✗ C: cycle.unconverged reason=divergence

integration: FAIL /Users/ericziegler/.zbuild/state/runs/20260824174903-48827/scratch/test/zbuild-test-stage.1p022q/tests/integration/route-tautolo
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-5/SPEC-6 tagged as [guard] but the assertion FAILS at the merge-base — a guard must hold there by definition, so either the assertion contradicts its SPEC text or the SPEC is a mislabelled [change]
- failures:
    - guard_regressed:SPEC-5
    - guard_regressed:SPEC-6

