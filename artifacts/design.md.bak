# Design: Migrate plan plugin to contract v2 (issue #1835)

## Summary

**Goal.** Bring `plugins/agent/plan` into full conformance with the v2
stage↔engine contract (ADR-054, ADR-055): v2 result fields in plan.json on every
exit path, `intake_goal` input replacing `goal_string`, disposition vocabulary
(current set per #2187), `rc ∈ {0,1}`, `valid_verdicts` updated, router budgets
in manifest, and the stale v1 comment in runner.sh updated.

**Context.** The plan plugin predates the v2 contract. Its manifest declares
`valid_verdicts: []` (no verdict) and has no `result_contract` field.
`plan_run` returns rc=2 on early-exit conditions the contract requires to be
rc=1, and rc=10 for scope_too_large where the v2 contract requires rc=1 with
`disposition=out_of_turns` written into the primary output. The `scope_manifest`
path is hard-coded from `dirname(state_file)` rather than read from
`ZBUILD_STAGE_INPUTS`. No v2 fields are written, so `_verdict_read_result` cannot
surface disposition to the engine.

The `goal_string` input is declared `source: external, required: false` with a
comment in the manifest explicitly noting "#1835 replaces it with the
`intake_goal` input." Other already-migrated plugins (review-lens, security-lens,
issue-acceptance, spec-coverage, review-report) all declare `intake_goal`
as a stage input and read it from `ZBUILD_STAGE_INPUTS`. `intake_goal` is
`intake`'s output at `${state_dir}/intake.md`.

**Re-verification against HEAD (commit dacf305b, 3 commits since prior design):**

Changes since the prior design:

1. **ADR-054 §6a (2026-09-25, #2187) amended the disposition vocabulary.** `exhausted`
   is retired; new words are `unusable`, `timed_out`, `out_of_turns`, `rate_limited`,
   `misconfigured`, `broken`. `disposition.sh` confirms the closed set. The prior
   design's SPEC-3 (out_of_turns for scope_too_large) is correct. SPEC-8's "timed_out,
   interrupted" list should now include `misconfigured` (router config errors map
   there via `router_reason_disposition`). `router_reason_disposition` in
   `scripts/lib/router-rc-classify.sh` maps: router_timeout → timed_out,
   router_out_of_turns|max_iterations → out_of_turns, router_config_error |
   router_budget_exceeded → misconfigured, no_progress → unusable.

2. **The stale comment in runner.sh moved** from line 2832 to line 2873 and now
   reads: "plan says `scope_too_large` with rc=10 and has nowhere else to put it."
   After migration this is false; the comment needs updating.

3. **rc=10 handlers in runner.sh (lines 3215, 3506, 3913) are NOT deleted by this
   migration.** `review-lens` also returns rc=10 (it's v2, so its rc=10 is narrowed
   by `dispatch_rc_narrow`), confirming plan was not uniquely the only rc=10
   emitter. The rc=10 handlers will become unreachable for plan (dispatch_rc_narrow
   at line 2885 fires because `_verdict_probe_contract` finds plan.json with
   `result_contract:2`), but remain in place as safety nets. The original plan
   task's "leaf path's rc=10 branch deleted" is achieved through narrowing, not
   removal.

4. **`plan-integration-test.sh` SPEC-3 currently asserts `rc=10` and "no fake
   plan.json written".** Both assertions must flip: rc=1 and plan.json IS written
   (with v2 fields). This test is the primary `[change]` target for SPEC-3.

5. **`plugins/agent/plan/manifest.yaml` changed**: acquired `plan-checkpoint.md`
   output (role: checkpoint, #1879) and `plan-summary.md` output (summary: true,
   ADR-055 §9) since initial writing. These are guards — migration must not remove
   them.

**Decision.** Follow the build plugin as the reference implementation for
enriching the primary JSON output with v2 fields inline (build-summary.json
carries both `schema_version:4` and `result_contract:2`). Enrich plan.json on
every terminal path with `result_contract:2, verdict, disposition, reason` so
that `_verdict_read_result` — which reads from the PRIMARY output — can surface
disposition to the engine. On success, plan.json carries both plan data and v2
fields. On failure paths, write a minimal plan.json with only v2 fields (matching
build's pattern on early-exit paths). Optionally add `plan-result.json` as a
declared secondary for observability (matches prior design); omit only if it
conflicts with the simplest implementation.

Disposition table (per disposition.sh closed set, ADR-054 §6a #2187):
- success → complete
- schema/empty/invalid_plan_response → unusable
- scope_too_large (max_turns exhaustion) → out_of_turns
- router timeout → timed_out (via `router_reason_disposition`)
- signal/oom → interrupted (via `router_reason_disposition`)
- router config error → misconfigured (via `router_reason_disposition`)
- missing state_file / unresolvable goal → broken (engine contract violation)

Update manifest: `result_contract:2` in provides, `valid_verdicts: [pass, error]`,
`config.router.timeout_s: 300, max_turns: 45`, a `plan-result.json` output entry.
Change all `return 2` paths in `plan_run` / `_plan_run_inner` to `return 1`.
Replace `goal_string` input (source: external) with `intake_goal` input (reading
from `ZBUILD_STAGE_INPUTS` like review-lens does). Remove hardcoded
`$state_dir/intake.md` fallback and `$state_dir/scope-manifest.md` construction.
Change the scope_too_large `return 10` to `return 1`. Update stale comment at
runner.sh line 2873. Update `plan-integration-test.sh` SPEC-3 to assert rc=1 and
that plan.json IS written with v2 fields.

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
tests/unit/dispatch-rc-test.sh
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
tests/e2e/parity-local-vs-ci-test.sh
tests/golden/plan-artifact.golden
tests/unit/plugin-artifact-goldens-test.sh
```

```acceptance
SPEC-1[change]: success path writes plan.json with result_contract:2, verdict=pass, disposition=complete, reason populated; _verdict_read_result can read disposition from plan.json primary and surface complete to the engine
SPEC-2[change]: error path (schema_violation / empty_result_envelope / invalid_plan_response) writes plan.json with result_contract:2, verdict=error, disposition=unusable, rc=1
SPEC-3[change]: scope_too_large path (max_turns exhaustion) writes plan.json with result_contract:2, verdict=error, disposition=out_of_turns, rc=1 — plan-integration-test.sh SPEC-3 currently asserts rc=10 and no plan.json; after migration it must assert rc=1 and plan.json present with out_of_turns
SPEC-4[change]: manifest declares provides.result_contract=2 and config.valid_verdicts contains pass and error
SPEC-5[change]: plan_run reads scope_manifest path from ZBUILD_STAGE_INPUTS index when the env var is set (mirrors review-lens / security-lens pattern)
SPEC-6[change]: plan_run returns rc=1 (not rc=2) when state_file argument is missing; and disposition=broken when state_file is the engine's responsibility — this is an engine contract violation
SPEC-7[guard]: existing plan.json primary output is still written on success and its content (schema_version, steps[], scope_files) is unchanged
SPEC-8[change]: non-max_turns router failure (rc≠0, not recovered, subtype≠error_max_turns) writes plan.json with disposition resolved via router_reason_disposition — timed_out for router timeout, interrupted for signal/oom, misconfigured for router config errors; verdict=error; rc=1
SPEC-9[change]: manifest config.router declares max_turns: 45 and timeout_s: 300; _route_resolve_max_turns returns 45 and _route_resolve_timeout returns 300 when no template or env override is set
SPEC-10[guard]: plan manifest's plan output entry declares primary: true
SPEC-11[change]: plan_run replaces goal_string (source: external) with intake_goal input; reads goal from ZBUILD_STAGE_INPUTS-provided path; removes hardcoded $state_dir/intake.md fallback; when intake_goal path is absent or unreadable, writes plan.json with disposition=broken and returns rc=1
SPEC-12[change]: plugin.sh contains no hardcoded input paths constructed from $state_dir/ beyond the authorized artifacts_dir derivation — grep -E '\$state_dir/[[:alnum:]]' plugin.sh | grep -v artifacts returns empty; at merge-base lines 111 (scope-manifest.md) and 117-118 (intake.md) match, so the assertion fails there
SPEC-13[guard]: manifest declares provides.role: planner (required by #1704); migration must not remove this field
SPEC-14[guard]: manifest declares provides.events with at least the plan plugin's current 9-event vocabulary (plan.context.persisted, plan.context.resume_skipped, plan.context.resumed, plan.dod_violation, plan.envelope.recovered, plan.flow_wiring_missing, plan.scope.violation, plan.scope_too_large, plan.router_failed); required by #1717
SPEC-15[guard]: manifest declares plan-summary.md output with summary: true and plan-checkpoint.md output with role: checkpoint — both added before #1835 and must survive migration
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
```

LOOP_COMPLETE
