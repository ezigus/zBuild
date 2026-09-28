# Design: Migrate deploy plugin to result_contract v2 (issue #1846)

## Architectural Decision Summary

**Goal:** Migrate `plugins/agent/deploy` to the v2 result contract (ADR-054, ADR-055, ADR-060):
every terminal exit path writes `{result_contract:2, verdict, disposition, reason, data}`;
input resolution via `ZBUILD_STAGE_INPUTS`; output path from `ZBUILD_ARTIFACT_DIR`; rc ∈ {0,1};
explicit disposition values; and `result_contract:2` in the manifest `provides` block.

**Context:** The deploy plugin still uses the v1 pattern throughout `plugin.sh`:
- All result writes use `schema_version:1` (five call-sites: missing pr_url, dry-run, missing gate, gate-not-pass/skipped, deploy-release failure, deploy-release absent).
- Paths are derived from `state_file` arg: `local artifacts_dir="$state_dir/artifacts"` at line 52, hardcoding `pr-url.txt` and `gate-aggregator-result.json` at lines 54–55.
- Error paths return rc=2 (lines 67, 96, 146) — ADR-054 requires rc ∈ {0,1}.
- The manifest `provides` block has no `result_contract` field.
- The unit test (`deploy-test.sh`) asserts `schema_version=1` (SPEC-7) and `rc=2` for missing gate (SPEC-8) — both will need inversion.
- The integration test (`deployed-template-e2e-test.sh`) dispatches deploy without `ZBUILD_STAGE_INPUTS` or `ZBUILD_ARTIFACT_DIR` (unlike validate, which already uses `_inputs_resolve_stage` at lines 211–215).

**ADR-055 amendment (2026-09-28, current HEAD):** The amendment adds `under_review: true` input
marker and finding-ownership logic. The validate plugin (migrated in #1845) already marks its
`deploy_result` input `under_review: true`, making deploy the finding owner for validate's
judgments. This is the validate plugin's concern and requires no change to the deploy manifest
for this migration. The amendment is noted as context only; it does not alter the v2 migration scope.

**Decision:** Update manifest, plugin.sh, and unit tests for v2 contract. Update
`tests/integration/deployed-template-e2e-test.sh` to supply `ZBUILD_ARTIFACT_DIR` and
`ZBUILD_STAGE_INPUTS` before calling `deploy_agent_run`, matching the production dispatch path
(`lifecycle.sh` / `_inputs_resolve_stage`). Update `docs/wiki/plugins/deploy.md` to reflect
the v2 manifest shape.

```scope
plugins/agent/deploy/manifest.yaml
plugins/agent/deploy/plugin.sh
plugins/agent/deploy/tests/deploy-test.sh
tests/integration/deployed-template-e2e-test.sh
docs/wiki/plugins/deploy.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-060-stages-return-structure.md
docs/adr/ADR-054-stage-contract.md
core/plugin-registry/lifecycle.sh
config/templates/deployed.yaml
```

```acceptance
SPEC-1[guard]: deploy plugin.sh exists and deploy_agent_run is defined after source
SPEC-2[change]: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed (test uses ZBUILD_STAGE_INPUTS dispatch)
SPEC-3[change]: missing pr_url input → deploy_agent_run exits non-zero and writes verdict=error (test uses ZBUILD_STAGE_INPUTS dispatch)
SPEC-4[change]: gate verdict=fail → deploy-result.json verdict=skipped (fail-closed allowlist; test uses ZBUILD_STAGE_INPUTS dispatch)
SPEC-5[guard]: plugin.sh has "Role: deploy_agent" preamble comment
SPEC-6[guard]: no route_to_model call in non-comment code
SPEC-7[change]: dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
SPEC-8[change]: missing gate (non-dry-run) → fail-closed returns rc=1 (not rc=2)
SPEC-9[change]: manifest provides block declares result_contract: 2
SPEC-10[change]: every terminal exit path writes v2 envelope: result_contract=2, verdict, disposition, reason all present
SPEC-11[change]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR; no state_file-derived path
SPEC-12[change]: pr_url and gate_aggregator_result resolved via ZBUILD_STAGE_INPUTS; plugin.sh constructs no pr-url.txt or gate-aggregator-result.json path
SPEC-13[change]: all error exit paths return rc=1; no exit path returns rc=2 or higher
SPEC-14[change]: all three valid verdicts (deployed, error, skipped) are exercised with v2-shaped result in tests
SPEC-15[guard]: manifest has no config.router block; manifest_router_knob returns empty for timeout_s and max_turns
SPEC-16[guard]: manifest outputs.deploy_result retains primary: true
SPEC-17[guard]: manifest provides.role = deploy_agent; provides.events = exactly the four declared events
SPEC-18[guard]: manifest hooks block declares only run: deploy_agent_run; no cleanup: entry
SPEC-19[change]: dry-run deploy-result.json carries verdict=deployed, disposition=complete, reason present (full v2 envelope)
SPEC-20[change]: deploy-release returns non-zero → deploy-result.json disposition=unavailable
SPEC-21[change]: deploy-release plugin file absent → deploy-result.json disposition=broken
SPEC-22[guard]: manifest config.valid_verdicts lists exactly the three emittable verdicts: deployed, error, skipped
SPEC-23[change]: with ZBUILD_ARTIFACT_DIR set to a non-default path before deploy_agent_run, the result is written to ZBUILD_ARTIFACT_DIR (not a state-file-derived path); deploy_agent_run exits 0 in dry-run when both ZBUILD_ARTIFACT_DIR and ZBUILD_STAGE_INPUTS are supplied
WIRING:
plugins/agent/deploy/manifest.yaml
tests/integration/deployed-template-e2e-test.sh
TESTFILES:
SPEC-1: plugins/agent/deploy/tests/deploy-test.sh
SPEC-2: plugins/agent/deploy/tests/deploy-test.sh
SPEC-3: plugins/agent/deploy/tests/deploy-test.sh
SPEC-4: plugins/agent/deploy/tests/deploy-test.sh
SPEC-5: plugins/agent/deploy/tests/deploy-test.sh
SPEC-6: plugins/agent/deploy/tests/deploy-test.sh
SPEC-7: plugins/agent/deploy/tests/deploy-test.sh
SPEC-8: plugins/agent/deploy/tests/deploy-test.sh
SPEC-9: plugins/agent/deploy/tests/deploy-test.sh
SPEC-10: plugins/agent/deploy/tests/deploy-test.sh
SPEC-11: plugins/agent/deploy/tests/deploy-test.sh
SPEC-12: plugins/agent/deploy/tests/deploy-test.sh
SPEC-13: plugins/agent/deploy/tests/deploy-test.sh
SPEC-14: plugins/agent/deploy/tests/deploy-test.sh
SPEC-15: plugins/agent/deploy/tests/deploy-test.sh
SPEC-16: plugins/agent/deploy/tests/deploy-test.sh
SPEC-17: plugins/agent/deploy/tests/deploy-test.sh
SPEC-18: plugins/agent/deploy/tests/deploy-test.sh
SPEC-19: plugins/agent/deploy/tests/deploy-test.sh
SPEC-20: plugins/agent/deploy/tests/deploy-test.sh
SPEC-21: plugins/agent/deploy/tests/deploy-test.sh
SPEC-22: plugins/agent/deploy/tests/deploy-test.sh
SPEC-23: tests/integration/deployed-template-e2e-test.sh
```
