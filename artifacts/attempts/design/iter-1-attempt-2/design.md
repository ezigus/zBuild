# Design: Migrate plan plugin to contract v2 (issue #1835)

## Summary

**Goal.** Bring `plugins/agent/plan` into full conformance with the v2
stage↔engine contract (ADR-054, ADR-055): v2 fields in plan.json on every exit
path, disposition vocabulary, `rc ∈ {0,1}`, `valid_verdicts` updated, router
budgets explicit in manifest, `intake_goal` input replacing the hardcoded
`$state_dir/intake.md` fallback, and the runner.sh leaf-path rc=10 block deleted.

**Context.** The plan plugin predates the v2 contract. Its manifest had no
`result_contract` field, `valid_verdicts: []`, no declared `inputs:`, and no
explicit `router.timeout_s` / `max_turns`. `plan_run` returned rc=2 on early
exits, rc=10 on scope_too_large. The non-max_turns router failure path wrote no
result file. A stale rc=10 handler in runner.sh's leaf-path `stage:*` case wired
the old signal.

**Decision.** The implementation enriches plan.json directly with v2 fields
(`result_contract:2, verdict, disposition, reason`) on every terminal path —
no separate plan-result.json sidecar. On success, plan.json carries both plan
data and v2 fields. On failure paths, plan.json carries only v2 fields (no plan
data). The manifest gains `result_contract:2`, `valid_verdicts: [pass, error]`,
explicit `config.router.timeout_s: 300` and `max_turns: 45`, a declared
`inputs:` block (`scope_manifest`, `intake_goal`), `provides.role: planner`,
`provides.events` vocabulary, and `plan-summary.md` / `plan-checkpoint.md`
output entries. The runner.sh rc=10 leaf-path block is deleted, lowering the
legacy-rc count in `dispatch-rc-guard-test.sh` from 36 to 35.

**Re-verification (iteration 3, HEAD 7711e449).** The acceptance-gate confirmed
that SPEC-10, SPEC-13, SPEC-14, SPEC-15, SPEC-17 — tagged `[guard]` in the
prior design — **FAIL at the merge-base**. A guard must hold at the merge-base
by definition. The empirical result overrules the prior design's claim that
`provides.role: planner` (#1704) and `provides.events` (#1717) were pre-existing:
at the current merge-base these fields are absent from the manifest, and the
migration adds them. All five SPECs are re-tagged `[change]`.

Two additional failures not covered by prior scope:

1. **`plan-integration-test.sh` stale SPEC-3 assertions** (lines ~236–262):
   pre-migration `[SPEC-3]` assertions (from issue #1052) still test `rc=10`
   and `no plan.json written on scope_too_large`. After migration these fail.
   They must be removed; `plan-integration-test.sh` is already in scope.

2. **`dispatch-rc-guard-test.sh` pin** at `core/pipeline/runner.sh|36` must
   become `35` — the rc=10 block deletion shrank the file's legacy-rc count.
   `tests/unit/dispatch-rc-guard-test.sh` was absent from prior scope; added.

**Shape-floor gate.** `core/pipeline/runner.sh` is listed in
`config/shape-change-paths.txt`. Its change triggers the shape-floor gate, which
requires that all event-sequence goldens and all `_TPL_STAGES[N]`-indexed order
assertion test files appear in the diff. Eight files were absent; all added to
scope below.

```scope
plugins/agent/plan/manifest.yaml
plugins/agent/plan/plugin.sh
plugins/agent/plan/tests/plan-test.sh
plugins/agent/plan/tests/plan-integration-test.sh
core/pipeline/disposition.sh
core/pipeline/runner.sh
core/pipeline/verdict.sh
scripts/lib/router-rc-classify.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/plan.md
tests/unit/plan-prompt-override-test.sh
tests/unit/plan-persona-framing-test.sh
tests/unit/plan-notes-contract-test.sh
tests/unit/plan-prompt-issue-discipline-test.sh
tests/unit/plan-context-lib-test.sh
tests/unit/stage-checkpoint-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/unit/engine-stage-reports-test.sh
tests/unit/abort-propagation-test.sh
tests/unit/router-manifest-budget-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/integration/agent-stage-banner-rendered-markdown-test.sh
tests/integration/dispatch-rc-signal-boundary-test.sh
tests/lib/run-status-comment-mock-roster.sh
tests/integration/cycle-on-max-pipeline-continues-test.sh
tests/integration/cycle-acceptance-terminal-failure-test.sh
tests/integration/cycle-rate-limit-aborts-run-test.sh
tests/integration/design-pipeline-test.sh
tests/unit/core-pipeline-contract-validator-test.sh
tests/unit/lint-contract-test.sh
tests/golden/parity/artifact-paths.golden
tests/golden/parity/event-sequence.golden
tests/golden/full-pipeline/event-sequence.golden
tests/e2e/parity-local-vs-ci-test.sh
tests/golden/plan-artifact.golden
tests/unit/plugin-artifact-goldens-test.sh
tests/unit/template-simple-yaml-test.sh
tests/unit/build-oos-pass-request-test.sh
tests/unit/core-pipeline-template-test.sh
tests/unit/template-resolvability-preflight-test.sh
tests/unit/impact-prefilter-order-detector-test.sh
```

```acceptance
SPEC-1[change]: success path writes plan.json with result_contract:2, verdict=pass, disposition=complete, reason non-empty; _verdict_read_result exposes disposition=complete to the engine via plan.json primary
SPEC-2[change]: error path (schema_violation / empty_result_envelope / invalid_plan_response) writes plan.json with result_contract:2, verdict=error, disposition=unusable, and returns rc=1
SPEC-3[change]: scope_too_large path (max_turns exhaustion) writes plan.json with result_contract:2, verdict=error, disposition=out_of_turns and returns rc=1 (NOT rc=10); plan.scope_too_large event still fires; old [SPEC-3] assertions in plan-integration-test.sh (lines ~236-262) that expected rc=10 and no plan.json are removed
SPEC-4[change]: manifest declares provides.result_contract=2 and config.valid_verdicts contains pass and error
SPEC-5[change]: plan_run reads scope_manifest path from ZBUILD_STAGE_INPUTS index when the env var is set (mirrors design plugin pattern)
SPEC-6[change]: plan_run returns rc=1 (not rc=2) when state_file argument is missing; plan.json written with result_contract:2 and disposition=broken
SPEC-7[guard]: existing plan.json primary output is still written on success and its content (schema_version, steps[], scope_files) is unchanged
SPEC-8[change]: non-max_turns router failure path (rc≠0, not recovered, subtype≠error_max_turns) writes plan.json with disposition resolved via router_reason_disposition (interrupted for signal/oom, timed_out for router timeout, misconfigured for config error), verdict=error, rc=1
SPEC-9[change]: manifest config.router declares max_turns: 45 and timeout_s: 300; _route_resolve_max_turns returns 45 and _route_resolve_timeout returns 300 when no template or env override is set
SPEC-10[change]: plan manifest's plan output entry declares primary: true
SPEC-11[change]: plan_run replaces goal_string (source: external) with intake_goal input; reads goal from ZBUILD_STAGE_INPUTS intake_goal path when provided; when intake_goal path is absent, plan_run writes plan.json with disposition=broken and returns rc=1; hardcoded $state_dir/intake.md fallback is removed
SPEC-12[change]: plugin.sh contains no hardcoded input paths constructed from $state_dir/ beyond the authorized artifacts_dir derivation — verified by grep: grep -E '\$state_dir/[[:alnum:]]' plugin.sh | grep -v artifacts returns empty; at merge-base lines 111 (scope-manifest.md) and 117-118 (intake.md) match, so the assertion fails there
SPEC-13[change]: manifest declares provides.role: planner
SPEC-14[change]: manifest declares provides.events with at least the plan plugin's 9-event vocabulary (plan.context.persisted, plan.context.resume_skipped, plan.context.resumed, plan.dod_violation, plan.envelope.recovered, plan.flow_wiring_missing, plan.scope.violation, plan.scope_too_large, plan.router_failed)
SPEC-15[change]: manifest declares plan-summary.md output with summary: true and plan-checkpoint.md output with role: checkpoint
SPEC-16[change]: runner.sh leaf-path `stage:*` case rc=10 block deleted — the block carrying "plan turn budget exhausted" is absent; dispatch-rc-guard-test.sh pin for runner.sh lowered from 36 to 35
SPEC-17[change]: manifest config.router retains retries: 1 and retry_on_exhaustion: 1; neither is removed by this migration
WIRING:
plugins/agent/plan/manifest.yaml
TESTFILES:
SPEC-1: plugins/agent/plan/tests/plan-test.sh
SPEC-2: plugins/agent/plan/tests/plan-test.sh
SPEC-3: plugins/agent/plan/tests/plan-integration-test.sh
SPEC-4: plugins/agent/plan/tests/plan-test.sh
SPEC-5: plugins/agent/plan/tests/plan-test.sh
SPEC-6: plugins/agent/plan/tests/plan-test.sh
SPEC-7: plugins/agent/plan/tests/plan-test.sh
SPEC-8: plugins/agent/plan/tests/plan-integration-test.sh
SPEC-9: plugins/agent/plan/tests/plan-test.sh
SPEC-10: plugins/agent/plan/tests/plan-test.sh
SPEC-11: plugins/agent/plan/tests/plan-test.sh
SPEC-12: plugins/agent/plan/tests/plan-test.sh
SPEC-13: plugins/agent/plan/tests/plan-test.sh
SPEC-14: plugins/agent/plan/tests/plan-test.sh
SPEC-15: plugins/agent/plan/tests/plan-test.sh
SPEC-16: tests/unit/dispatch-rc-guard-test.sh
SPEC-17: plugins/agent/plan/tests/plan-test.sh
```

LOOP_COMPLETE
