# Gate Aggregator Feedback

The build_test_cycle did not converge: 2 mechanical gate(s) failed. Address every finding below, then re-run.

## test

- test output:
```

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: 373/377 passed (4 skipped)
integration: 232/235 passed
e2e: 6/8 passed
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
  PASS  pipeline-contracts.md  (caught: rc=127)
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
  PASS  router-route-mutations.md  (caught: rc=1)
  PASS  runner-fail-closed-mutations.md  (caught: rc=127)
  PASS  scope-redaction-mutations.md  (caught: rc=3)
mutation-infra: 1 non-fatal (worktree/patch contention; excluded from score — #1184)
mutation: 23/23 passed
lint: 1/1 passed
unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.TZ5tr4/tests/unit/router-manifest-budget-test.sh

  router manifest budget — plugin-declared timeout_s/max_turns/retries (#1816)


  [SPEC-0] sourcing route.sh alone provides the manifest reader
  ✓ route.sh brings manifest_router_knob by construction

  [SPEC-1] a manifest with no config.router block is byte-identical to today
  ✓ timeout_s falls to the 300s constant
  ✓ max_turns falls to the 25 constant
  ✓ retries falls to the 0 constant (opt-in, unchanged)
  ✓ no ZBUILD_PLUGIN_DIR at all → 300s constant
  ✓ no ZBUILD_PLUGIN_DIR at all → 25 constant
  ✓ no ZBUILD_PLUGIN_DIR at all → 0 constant
  ✓ ZBUILD_PLUGIN_DIR without a manifest.yaml → constant, no failure

  [SPEC-2] config.router.* is read as the default
  ✓ manifest timeout_s beats the 300s constant
  ✓ manifest max_turns beats the 25 constant
  ✓ manifest retries beats the 0 constant
  ✓ a partial declaration leaves the undeclared knobs on the constant
  ✓ a top-level router: block is NOT the plugin's declaration
  ✓ comments on config:/router:/the value do not hide the declaration
  ✓ a later top-level key closes the block (provides.timeout_s is not it)
  ✓ an undeclared knob in a commented block still falls to the constant
  ✓ a comment BETWEEN knobs does not drop the ones after it

  [SPEC-3] the operator env knob still wins over the manifest
  ✓ ZBUILD_ROUTER_TIMEOUT beats manifest timeout_s
  ✓ ZBUILD_ROUTER_MAX_TURNS beats manifest max_turns
  ✓ ZBUILD_ROUTER_RETRIES beats manifest retries

  [SPEC-4] the template accessor still wins over the manifest
  ✓ template timeout_s wins over manifest timeout_s
  ✓ template max_turns wins over manifest max_turns
  ✓ template retries wins over manifest retries

  [SPEC-5] router.*.override_ignored still fires for env-vs-template
  ✓ env-vs-template override_ignored event still emitted
  ✓ the event reports the applied (template) value
  ✓ manifest-loses-to-env emits no override_ignored event

  [SPEC-6] malformed manifest values fall back, never propagate
  ✓ non-numeric timeout_s falls to the constant
  ✓ out-of-range max_turns falls to the constant
  ✓ negative retries falls to the constant

  [SPEC-7] ZBUILD_ROUTER_MAX_TURNS_OVERRIDE still outranks all layers
  ✓ cycle-orchestrator escalation beats template, env AND manifest

  [SPEC-7b] a manifest-declared max_turns: 0 classifies as 'manifest'
  ✓ the sentinel resolves to 0 from the manifest
  ✓ and the telemetry names the manifest, not the default
  ✓ a plugin declaring nothing still classifies as default
  ✓ an env 0 still classifies as env, even with a manifest 0 present

  [SPEC-8] manifest_router_knob reads config.router.<knob>
  ✓ reads a declared knob
  ✓ empty for an undeclared knob
  ✓ empty for a missing file (no error)
  ✓ does not read a top-level router: block
  ✓ tier_default is not a router knob

  [SPEC-9] validate_manifest accepts a well-formed block, rejects a malformed one
  ✓ accepts a well-formed config.router block
  ✓ rejects a non-numeric timeout_s
  ✓ rejects an out-of-range timeout_s (>3600)
  ✓ rejects timeout_s: 0 (matches the template range 1..3600)
  ✓ rejects an out-of-range max_turns (>200)
  ✓ rejects an out-of-range retries (>10)
  ✓ accepts the 0 sentinels the template already accepts
  ✓ rejects an unknown key inside config.router (a typo is inert, not silent)

  [SPEC-10] every shipped plugin manifest still passes validate_manifest
  ✗ no shipped manifest is rejected by the new schema check
    expected: , got: plugins/agent/build/manifest.yaml 


  1 of 48 tests failed

  ✗ no shipped manifest is rejected by the new schema check

unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.TZ5tr4/tests/unit/stage-checkpoint-test.sh

  stage checkpoint — declaration, injection, splice-back (#1879)


  1. a declaring stage gets the checkpoint block
  ✓ [SPEC-1] the block is emitted
  ✓ [SPEC-1] it carries the RESOLVED path as a literal
  ✓ [SPEC-1] the path is interpolated, not raw

  2. a non-declaring stage is untouched
  ✓ [SPEC-2] no declaration -> empty block

  3. the checkpoint path is outside the repository
  ✓ [SPEC-3] the checkpoint path is outside the repo

  4. a prior checkpoint from THIS run is spliced back
  ✓ [SPEC-4] the prior body is spliced in
  ✓ [SPEC-4] under a resumed-exploration heading

  5. a prior RUN's checkpoint is spliced back
  ✓ [SPEC-5] the restored body is spliced in

  6. the live checkpoint wins over the restored one
  ✓ [SPEC-6] the live body is used
  ✓ [SPEC-6] the stale cross-run body must not be used

  7. injected at the shared router funnel, idempotently
  ✓ [SPEC-7] the funnel injects the block
  ✓ [SPEC-7] exactly one block after the first pass
  ✓ [SPEC-7] still exactly one after a second pass (idempotent)
  ✓ [SPEC-8] the original prompt body is preserved
  ✓ [SPEC-7-guard] a non-declaring stage gets no checkpoint block
  ✓ [SPEC-7-guard] and its own body is preserved

  9. budget exhaustion is detected, and opt-in per stage
  ✓ [SPEC-9] subtype error_max_turns is exhaustion
  ✓ [SPEC-9] terminal_reason max_turns is exhaustion
  ✓ [SPEC-9] a rate limit is not budget exhaustion
  ✓ [SPEC-9] a success is not budget exhaustion

  10. the opt-in is per stage, and impact is untouched
  ✓ [SPEC-10] plan opts in to one exhaustion retry
  ✗ [SPEC-10] plan is the ONLY stage opted in
    expected: plan , got: build plan 
  ✓ [SPEC-10] impact declares no exhaustion retry

  11. the retry's escalated --max-turns reaches the argv
  ✓ [SPEC-11] 45 escalates to 67 (+50%, under the 2x cap)
  ✓ [SPEC-11] and the argv carries the escalated value
  ✓ [SPEC-11] the stale budget must not survive in the argv
  ✓ [SPEC-11] a second escalation is capped at 2x BASE, not 2x current
  ✓ [SPEC-11] max_turns=0 (unbounded) stays 0

  12. route.sh rewrites the argv, not just the variable
  ✓ [SPEC-12] the exhaustion retry rewrites --max-turns in _claude_args
  ✓ [SPEC-12] the cap is computed against the original budget


  1 of 30 tests failed

  ✗ [SPEC-10] plan is the ONLY stage opted in

unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.TZ5tr4/tests/unit/stage-resolution-parity-test.sh

  core/pipeline/dispatch.sh — resolve_stage_plugin role-then-id parity (ADR-042)

  ✓ [SETUP] simple.yaml loads without error
  ✓ [SPEC-1] id-only (_find_plugin_for_stage) returns EMPTY for acceptance-gate
  ✓ [SPEC-1] id-only returns EMPTY for review_lenses (no id-match plugin, only role-match)
  ✓ [SPEC-2] map group review_lenses → review-lens
  ✓ [SPEC-2] review-aggregator → review-aggregator (role review_aggregator)
  ✓ [SPEC-2] resolved review-lens plugin dir has a manifest
  ✓ [SPEC-3] test → test (role tester)
  ✓ [SPEC-3] shape-floor → shape-floor
  ✓ [SPEC-3] acceptance-gate → spec-acceptance (role acceptance_gate)
  ✓ [SPEC-3] secret-scan → secret-scan
  ✓ [SPEC-3] gate-aggregator → gate-aggregator
  ✗ [SPEC-3] build → build (role: builder)
    expected: build, got: 
  ✓ [SPEC-4] unknown stage resolves to EMPTY stdout
  ✓ [SPEC-4] unknown stage returns rc=1 (miss)
  ✓ [SPEC-5] fail-closed: ghost role declared → rc=1 (no id-match fallback)
  ✓ [SPEC-7] pr stage resolves to pr-delivery (role: pr, not id-match to pr-open)


  1 of 16 tests failed

  ✗ [SPEC-3] build → build (role: builder)

unit: FAIL /home/runner/work/_temp/zbuild-state/scratch/test/zbuild-test-stage.TZ5tr4/tests/unit/template-resolvability-preflight-test.sh

  template resolvability preflight + fictitious-stage harness (#1282)

  ✓ SPEC-1: fictitious-stage template loads (rc=0)
  ✓ SPEC-1: _TPL_STAGES contains the fictitious leaf
  ✓ SPEC-2: fictitious leaf resolves to its plugin dir
  ✓ SPEC-2b: resolvability preflight passes for resolvable leaf (rc=0)
  ✓ SPEC-3a: template.sh byte-identical after onboarding a fictitious stage
  ✓ SPEC-3b: template.sh names no fixture stage (mechanics name no stage)
  ✓ SPEC-4: unresolvable leaf → preflight returns non-zero (fail-closed)
  ✓ SPEC-4b: error names the unresolvable id
  ✓ SPEC-4c: error is the pinned ADR-047 §5 resolvability message
  ✓ SPEC-5: empty leaf set → preflight passes (rc=0)
  corpus REGRESSION: deployed.yaml has an unresolvable leaf
  corpus REGRESSION: simple.yaml has an unresolvable leaf
  ✗ [SPEC-6] shipped corpus loads and every leaf resolves (preflight accepts, corpus=3)
    expected: 1, got: 0
  ✓ SPEC-6b: preflight rejects both genuinely-unresolvable-leaf templates
  ✓ SPEC-7: residual — swapped resolvable leaves still resolve (accepted, rc=0)
  ✓ [SPEC-8] fail-closed: ghost_role declared, id-match plugin exists → rc=1
  ✓ [SPEC-8] fail-closed error output name
```

## acceptance-gate

- reason: acceptance SPEC violations — SPEC-7/SPEC-14 tautological (pass at baseline) — re-author the assertions; SPEC-8 not passing at HEAD — fix the implementation or the assertion; WIRING plugins/agent/build/manifest.yaml/plugins/agent/build/lib/summary.sh/plugins/agent/build/plugin.sh inert — reverting it breaks no TESTFILE
- failures:
    - tautology:SPEC-7
    - not_passing_at_head:SPEC-8
    - tautology:SPEC-14
    - inert_wiring:plugins/agent/build/manifest.yaml
    - inert_wiring:plugins/agent/build/lib/summary.sh
    - inert_wiring:plugins/agent/build/plugin.sh

