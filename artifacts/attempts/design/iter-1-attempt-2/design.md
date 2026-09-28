# Design: Migrate deploy plugin to result_contract v2 (issue #1846)

## Architectural Decision Summary

**Goal:** Migrate `plugins/agent/deploy` to the v2 result contract (ADR-055 §1, ADR-060): every terminal exit path writes `{result_contract:2, verdict, disposition, reason, data}`; input resolution via `ZBUILD_STAGE_INPUTS`; output path from `ZBUILD_ARTIFACT_DIR`; rc ∈ {0,1}; explicit disposition values; `result_contract:2` in the manifest `provides` block.

**Context:** The deploy plugin was last touched for issue #757 (gate-bypass hardening). It still uses the v1 pattern: output path derived from the state_file argument, inputs constructed via hardcoded `$artifacts_dir/pr-url.txt` and `$artifacts_dir/gate-aggregator-result.json`, and result shape with `schema_version` not `result_contract`. The integration test (`deployed-template-e2e-test.sh`) dispatches the plugin directly without supplying `ZBUILD_ARTIFACT_DIR` or `ZBUILD_STAGE_INPUTS` — which worked for v1 (path derived from state_file) but breaks after the v2 migration.

**Decision:** Update manifest, plugin.sh, and unit tests for v2 contract. Additionally update `tests/integration/deployed-template-e2e-test.sh` to supply `ZBUILD_ARTIFACT_DIR` and `ZBUILD_STAGE_INPUTS` before calling `deploy_agent_run`, matching how `lifecycle.sh` dispatches plugins in production. Update `docs/wiki/plugins/deploy.md` to reflect the v2 manifest shape.

**SPEC classification correction:** SPEC-2, SPEC-3, SPEC-4 were labelled `[guard]` but each FAILS at the merge-base baseline (v1 plugin does not read `ZBUILD_STAGE_INPUTS`; the unit test's `_make_state` helper puts inputs there, so the v1 plugin never finds pr_url or gate file). These are genuine `[change]` behaviors introduced by this migration, not invariants that hold at the baseline.

```scope
plugins/agent/deploy/manifest.yaml
plugins/agent/deploy/plugin.sh
plugins/agent/deploy/tests/deploy-test.sh
tests/integration/deployed-template-e2e-test.sh
docs/wiki/plugins/deploy.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-060-stages-return-structure.md
core/plugin-registry/lifecycle.sh
```

```acceptance
SPEC-1[guard]: deploy plugin.sh exists and deploy_agent_run is defined after source
SPEC-2[change]: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
SPEC-3[change]: missing pr_url input → deploy_agent_run exits non-zero and writes verdict=error
SPEC-4[change]: gate verdict=fail → deploy-result.json verdict=skipped (fail-closed allowlist)
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
