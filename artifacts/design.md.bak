# Design: Migrate plan plugin to contract v2 (issue #1835)

## Summary

**Goal.** Bring `plugins/agent/plan` into full conformance with the v2
stage↔engine contract (ADR-054, ADR-055): v2 result file on every exit path,
disposition vocabulary, `rc ∈ {0,1}`, `valid_verdicts` updated, router
budgets explicit in manifest, name-matched `scope_manifest` input via
`ZBUILD_STAGE_INPUTS`, primary output confirmed, `provides.result_contract:2`
declared, cleanup correctly absent.

**Context.** The plan plugin predates the v2 contract.  Its manifest today
declares `valid_verdicts: []` (no verdict on the primary) and has no
`result_contract` field.  `plan_run` returns rc=2 on early-exit conditions
that the contract requires to be rc=1.  The scope_manifest path is hard-coded
from `dirname(state_file)` rather than read from `ZBUILD_STAGE_INPUTS`.  No
`plan-result.json` sidecar is written, so the engine cannot read a disposition
for retry decisions.

**Decision.** Follow the teardown and design plugins as reference
implementations.  Add a `_plan_write_result` helper that writes
`plan-result.json` (result_contract:2, verdict, disposition, reason, data)
and call it on every terminal exit path.  Update the manifest with
`result_contract:2`, `valid_verdicts: [pass, error]`, router budgets
(`timeout_s: 300, max_turns: 45`), and a `plan-result.json` output entry.
Change the two `return 2` early-exit paths in `plan_run` to `return 1`.  Read
`scope_manifest` from `ZBUILD_STAGE_INPUTS` when available, falling back to
the constructed path.  The `scope_too_large` path (rc=10) is the one
engine-special code exempted from rc ∈ {0,1}; it writes
`verdict=error, disposition=out_of_turns` in the result file before returning.

```scope
plugins/agent/plan/manifest.yaml
plugins/agent/plan/plugin.sh
plugins/agent/plan/tests/plan-test.sh
plugins/agent/plan/tests/plan-integration-test.sh
core/pipeline/disposition.sh
scripts/lib/router-rc-classify.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/plan.md
tests/unit/plan-prompt-override-test.sh
tests/unit/plan-persona-framing-test.sh
tests/unit/plan-notes-contract-test.sh
tests/unit/plan-prompt-issue-discipline-test.sh
tests/unit/stage-checkpoint-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/unit/engine-stage-reports-test.sh
tests/integration/agent-stage-banner-rendered-markdown-test.sh
tests/lib/run-status-comment-mock-roster.sh
tests/integration/cycle-on-max-pipeline-continues-test.sh
tests/integration/cycle-acceptance-terminal-failure-test.sh
tests/integration/cycle-rate-limit-aborts-run-test.sh
tests/integration/design-pipeline-test.sh
tests/unit/core-pipeline-contract-validator-test.sh
tests/unit/lint-contract-test.sh
```

```acceptance
SPEC-1[change]: success path writes plan-result.json with result_contract:2, verdict=pass, disposition=complete
SPEC-2[change]: error path (schema_violation / empty_result_envelope / invalid_plan_response) writes plan-result.json with result_contract:2, verdict=error, disposition=unusable
SPEC-3[change]: scope_too_large path writes plan-result.json with result_contract:2, verdict=error, disposition=out_of_turns before returning rc=10
SPEC-4[change]: manifest provides.result_contract=2 and config.valid_verdicts contains pass and error
SPEC-5[change]: plan_run reads scope_manifest path from ZBUILD_STAGE_INPUTS index when the env var is set (mirrors design plugin pattern)
SPEC-6[change]: plan_run returns rc=1 (not rc=2) when state_file argument is missing or goal_text is unresolvable
SPEC-7[guard]: existing plan.json primary output is still written on success and its content is unchanged
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
```
