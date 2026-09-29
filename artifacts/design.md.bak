# Design: Migrate plan plugin to contract v2 (issue #1835)

## Summary

**Goal.** Bring `plugins/agent/plan` into full conformance with the v2
stage↔engine contract (ADR-054, ADR-055): v2 result file on every exit path,
disposition vocabulary, `rc ∈ {0,1}`, `valid_verdicts` updated, router
budgets explicit in manifest, name-matched `scope_manifest` input via
`ZBUILD_STAGE_INPUTS`, primary output confirmed, `provides.result_contract:2`
declared, cleanup correctly absent.

**Context.** The plan plugin predates the v2 contract. Its manifest declares
`valid_verdicts: []` (no verdict on the primary) and has no `result_contract`
field. `plan_run` returns rc=2 on early-exit conditions the contract requires
to be rc=1, and rc=10 for scope_too_large where the v2 contract requires rc=1
with disposition=out_of_turns written into the result. The scope_manifest path
is hard-coded from `dirname(state_file)` rather than read from
`ZBUILD_STAGE_INPUTS`. No v2 result file is written, so the engine cannot read
a disposition for retry/abort decisions. The non-max_turns router-failure path
writes no result file and does not call `router_reason_disposition`, so
signals/oom/timeout produce wrong dispositions. Additionally, `plan_run` falls
back to constructing `$state_dir/intake.md` by hardcoded path when `ZBUILD_GOAL`
is unset — a second undeclared artifact path the v2 name-matched-inputs principle
prohibits.

**Decision.** Follow the build plugin as the reference implementation for
enriching the primary JSON output with v2 contract fields inline (as
build-summary.json carries both `schema_version:4` and `result_contract:2`).
Add a `_plan_write_result` helper that writes `plan-result.json` (a secondary
sidecar for observability), AND enrich plan.json on every terminal path with
`result_contract:2, verdict, disposition, reason` so that `_verdict_read_result`
— which reads only the PRIMARY output (plan.json) — can surface the disposition
to the engine. On success, plan.json carries both plan data and v2 fields. On
failure paths, write a minimal plan.json with only v2 contract fields (no plan
data — matching build's pattern on early-exit paths).

The disposition table: success → complete; schema/empty failures → unusable;
scope_too_large (max_turns exhaustion) → out_of_turns; non-max_turns router
failure → via `router_reason_disposition` (timed_out, interrupted, etc.);
missing-state-file / missing-goal early exits → unusable.

Update the manifest: `result_contract:2` in provides, `valid_verdicts: [pass,
error]`, `config.router.timeout_s: 300, max_turns: 45`, a `plan-result.json`
output entry. Change all `return 2` paths in `plan_run` to `return 1`. Read
`scope_manifest` from `ZBUILD_STAGE_INPUTS` when available. Remove the
hardcoded `$state_dir/intake.md` fallback: since `goal_string` is declared as
`required: true, source: external`, the engine guarantees `ZBUILD_GOAL` is set
for v2 plugins — the fallback is dead code that silently constructs an
undeclared artifact path. Change the scope_too_large `return 10` to `return 1`
— the engine reads disposition from the result file, not the exit code, for v2
plugins (runner.sh `runner_read_stage_disposition` already handles this via
`_verdict_read_result`). Update the stale comment in runner.sh at line 2832
that claims plan uses rc=10 as its sole v1 channel.

The manifest already carries `provides.role: planner` (added by #1704) and
`provides.events:` with 9 declared events (added by #1717). The migration must
not remove either. SPEC-13 and SPEC-14 guard these as invariants.

**Re-verification against HEAD (commit 900db6b0, 0 commits since prior design):**
- `plugins/agent/plan/plugin.sh`: `return 2` at lines 105 and 123 (plan_run),
  337 (_plan_run_inner); `return 10` at line 849; `$state_dir/scope-manifest.md`
  hardcoded at line 111; `$state_dir/intake.md` at lines 117–118, 122. No
  ZBUILD_STAGE_INPUTS usage. All prior-design claims verified exact.
- `plugins/agent/plan/manifest.yaml`: `valid_verdicts: []` at line 59; no
  `result_contract` field; `config.router` has `retries:1, retry_on_exhaustion:1`
  but no `timeout_s` or `max_turns`. `provides.role: planner` (line 21),
  9 events (lines 25–33), `primary: true` on plan output (line 77). Confirmed.
- `core/pipeline/runner.sh`: stale comment at lines 2832–2833 cites plan rc=10;
  rc=10 scope_too_large handlers still present; after migration, `dispatch_rc_narrow`
  at line 2844 narrows rc before these are reached.
- `scripts/lib/router-rc-classify.sh`: `router_reason_disposition` confirmed at
  line 259; `_route_resolve_max_turns` and `_route_resolve_timeout` also present.
- All other prior-scope files confirmed present and matching prior-design claims.

**Scope additions vs prior design (verified 2026-09-29):**
- `core/pipeline/verdict.sh` — `_verdict_read_result` reads `.result_contract // 1`
  from the primary output; at contract≥2 it reads `.disposition`, `.verdict`,
  `.reason` inline from plan.json. After enrichment, plan.json satisfies this
  constraint. Added to scope.
- `tests/golden/parity/artifact-paths.golden` — the parity e2e test
  (`tests/e2e/parity-local-vs-ci-test.sh` Test 14) compares actual artifact
  paths against this golden via `assert_golden "parity/artifact-paths"`. Since
  `plan-result.json` is a new declared output (written on every terminal path),
  it will appear in the artifact tree and must be added to this golden or the
  test fails. Confirmed by reading parity-local-vs-ci-test.sh line 206.
- `tests/e2e/parity-local-vs-ci-test.sh` — runs the real plan plugin via
  `tests/golden/parity/run-fixture.sh` (mock claude, real plugin code); the
  artifact-paths golden comparison at Test 14 is the failure site.
- `tests/golden/plan-artifact.golden` — canonical shape snapshot of plan.json;
  after migration plan.json carries v2 fields (`result_contract, verdict,
  disposition, reason`) and this golden should reflect the new shape. The test
  using it (`plugin-artifact-goldens-test.sh`) is self-referential so it won't
  fail automatically, but the golden must be updated to remain a correct fixture.
- `tests/unit/plugin-artifact-goldens-test.sh` — validates structural invariants
  of plan-artifact.golden (schema_version=1, non-empty steps). Must track the
  golden update.

**SPEC-12 rationale.** SPEC-5 and SPEC-11 address two specific hardcoded path
removals but leave open whether additional `$state_dir/<path>` constructions
survive. SPEC-12 closes this with a grep-based blanket assertion: after migration,
`grep -E '\$state_dir/[[:alnum:]]' plugin.sh | grep -v artifacts` returns empty.
At the merge-base, lines 111 (`$state_dir/scope-manifest.md`) and 117–118
(`$state_dir/intake.md`) both match — the grep FAILS there, making this a valid
`[change]`.

**SPEC-13/14 rationale.** `provides.role: planner` (#1704) and `provides.events`
with 9 events (#1717) already exist at the merge-base. They are `[guard]`
invariants — the migration must not remove them, but tagging them `[change]`
would be dishonest (the negative control cannot fail at baseline for something
already true).

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
SPEC-1[change]: success path writes plan-result.json with result_contract:2, verdict=pass, disposition=complete, and plan.json (primary) carries result_contract:2 so _verdict_read_result exposes disposition to the engine
SPEC-2[change]: error path (schema_violation / empty_result_envelope / invalid_plan_response) writes plan-result.json with result_contract:2, verdict=error, disposition=unusable; plan.json carries matching v2 fields
SPEC-3[change]: scope_too_large path writes plan-result.json with result_contract:2, verdict=error, disposition=out_of_turns and returns rc=1 (NOT rc=10; the engine reads out_of_turns from the result file via plan.json primary)
SPEC-4[change]: manifest provides.result_contract=2 and config.valid_verdicts contains pass and error
SPEC-5[change]: plan_run reads scope_manifest path from ZBUILD_STAGE_INPUTS index when the env var is set (mirrors design plugin pattern)
SPEC-6[change]: plan_run returns rc=1 (not rc=2) when state_file argument is missing or goal_text is unresolvable
SPEC-7[guard]: existing plan.json primary output is still written on success and its content (schema_version, steps[], scope_files) is unchanged
SPEC-8[change]: non-max_turns router failure path (rc≠0, not recovered, subtype≠error_max_turns) writes plan-result.json with disposition resolved via router_reason_disposition (interrupted for signal/oom, timed_out for router timeout), verdict=error, rc=1
SPEC-9[change]: manifest config.router declares max_turns: 45 and timeout_s: 300; _route_resolve_max_turns returns 45 and _route_resolve_timeout returns 300 when no template or env override is set; a template-level override beats the manifest value when set
SPEC-10[guard]: plan manifest's plan output entry declares primary: true
SPEC-11[change]: plan_run no longer constructs $state_dir/intake.md by hardcoded path — the legacy ZBUILD_GOAL fallback via intake.md is removed; when ZBUILD_GOAL is unset, plan_run writes result with disposition=unusable and returns rc=1 (goal_string is declared required/source:external so the engine guarantees ZBUILD_GOAL is set for v2 callers)
SPEC-12[change]: plugin.sh contains no hardcoded input paths constructed from $state_dir/ beyond the authorized artifacts_dir derivation — verified by grep: grep -E '\$state_dir/[[:alnum:]]' plugin.sh | grep -v artifacts returns empty; at merge-base this grep matches lines 111 (scope-manifest.md) and 117-118 (intake.md), so the assertion fails there
SPEC-13[guard]: manifest declares provides.role: planner (required by #1704); migration must not remove this field
SPEC-14[guard]: manifest declares provides.events with at least the plan plugin's current 9-event vocabulary (plan.context.persisted, plan.context.resume_skipped, plan.context.resumed, plan.dod_violation, plan.envelope.recovered, plan.flow_wiring_missing, plan.scope.violation, plan.scope_too_large, plan.router_failed); required by #1717
WIRING:
plugins/agent/plan/manifest.yaml
TESTFILES:
SPEC-1: plugins/agent/plan/tests/plan-test.sh
SPEC-2: plugins/agent/plan/tests/plan-test.sh
SPEC-3: plugins/agent/plan/tests/plan-test.sh
SPEC-4: plugins/agent/plan/tests/plan-test.sh
SPEC-5: plugins/agent/plan/tests/plan-test.sh
SPEC-6: plugins/agent/plan/tests/plan-test.sh
SPEC-7: plugins/agent/plan/tests/plan-test.sh
SPEC-8: plugins/agent/plan/tests/plan-test.sh
SPEC-9: plugins/agent/plan/tests/plan-test.sh
SPEC-10: plugins/agent/plan/tests/plan-test.sh
SPEC-11: plugins/agent/plan/tests/plan-test.sh
SPEC-12: plugins/agent/plan/tests/plan-test.sh
SPEC-13: plugins/agent/plan/tests/plan-test.sh
SPEC-14: plugins/agent/plan/tests/plan-test.sh
```

LOOP_COMPLETE
