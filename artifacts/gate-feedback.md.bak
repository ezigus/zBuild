# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 348/348 passed (4 skipped)
integration: 229/229 passed
e2e: 8/8 passed
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
  PASS  pipeline-contracts.md  (caught: rc=1)
  PASS  pipeline-dispatch-arg-mutations.md  (caught: rc=1)
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
lint: 0/1 passed
lint: FAIL (npm run lint)
 For more information:   https://www.shellcheck.net/wiki/SC2034 -- rc_ts appears unused. Verify use ... 

total: 609/610 passed (4 skipped)
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-4/SPEC-5 tagged as [guard] but the assertion FAILS at the merge-base — a guard must hold there by definition, so either the assertion contradicts its SPEC text or the SPEC is a mislabelled [change]
- failures:
    - guard_regressed:SPEC-4
    - guard_regressed:SPEC-5

