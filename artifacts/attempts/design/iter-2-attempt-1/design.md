# Design: Migrate deploy plugin to result_contract v2 (issue #1846)

## Architectural decision summary

**Goal.** Bring `plugins/agent/deploy` into full ADR-054/055 compliance: v2 result
envelope on every exit path, engine-resolved inputs via `ZBUILD_STAGE_INPUTS`, engine-
supplied output directory via `ZBUILD_ARTIFACT_DIR`, `rc ∈ {0,1}`, explicit disposition
values, and a `result_contract: 2` declaration in the manifest's `provides` block.

**Context.** The deploy plugin was authored before the v2 contract was formalised. It
currently derives its output path from the state-file argument (`$state_dir/artifacts`),
constructs its input paths by hardcoding `$artifacts_dir/pr-url.txt` and
`$artifacts_dir/gate-aggregator-result.json`, writes `schema_version:1` JSON on all
exit paths, and returns `rc=2` on several error paths. The `deploy-release` tool plugin
(#1849) has already migrated to v2; this issue completes the deploy agent's side.
The `validate` agent migration (#1845) is the canonical reference pattern.

**Decision.** (a) Add `result_contract: 2` to `provides` in the manifest. (b) Add a
`_deploy_write_result` helper analogous to `_validate_write_result` that emits
`result_contract:2, verdict, disposition, reason, data`. (c) Rewrite
`_deploy_agent_run_inner`: read `ZBUILD_ARTIFACT_DIR` for all writes; resolve `pr_url`
and `gate_aggregator_result` from `ZBUILD_STAGE_INPUTS`; delete the three hardcoded path
variables; map each failure mode to an explicit disposition (table below); clamp every
error return to `rc=1`. (d) In `deploy_agent_run`, write the no-state-file result to
`ZBUILD_ARTIFACT_DIR` and return `rc=1` instead of `rc=2`. (e) Write the new and updated
test assertions first (red step), then implement (green step). The fail-closed gate
allowlist, dry-run guard ordering, and delegation to `deploy_release_run` are preserved.

Two non-seed files also need to change:
`tests/integration/deployed-template-e2e-test.sh` invokes `deploy_agent_run` without
`ZBUILD_ARTIFACT_DIR` or `ZBUILD_STAGE_INPUTS` (lines 180–189); after v2 the plugin
returns `rc=1` on entry, failing SPEC-9. This test must set up these env vars for the
deploy invocation the same way it already does for validate (lines 211–212).
`docs/wiki/plugins/deploy.md` shows a stale manifest snapshot (`schema_version:1`, stale
input format with `source: stage:`, `cleanup:` hook entry); it must be updated.

## Disposition table

| exit path | verdict | disposition |
|---|---|---|
| no state_file (engine fault) | error | broken |
| ZBUILD_ARTIFACT_DIR absent | error | broken |
| pr_url missing from ZBUILD_STAGE_INPUTS | error | broken |
| gate-aggregator-result missing from index | error | broken |
| gate verdict ≠ pass (deliberate skip) | skipped | complete |
| dry-run | deployed | complete |
| deploy-release returns non-zero | error | unavailable |
| deploy-release plugin file missing | error | broken |
| success | deployed | complete |

```scope
plugins/agent/deploy/manifest.yaml
plugins/agent/deploy/plugin.sh
plugins/agent/deploy/tests/deploy-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/unit/plugin-route-source-guard-test.sh
docs/wiki/plugins/deploy.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
```

**Scope notes:**

`tests/unit/plugin-route-source-guard-test.sh` — SPEC-2 in this file asserts that
`plugins/agent/deploy/plugin.sh` mentions `route_to_model` in a comment-only context.
If the preamble is rewritten such that the text "route_to_model" is removed, the guard
fires: "drop it from `_COMMENT_ONLY` rather than leaving a vacuous case." The plugin
preamble must retain the "No LLM calls (no route_to_model)" comment.

`config/templates/deployed.yaml` — the deploy stage section in the template does not
change (role `deploy_agent`, no router, same io settings); no scope.

`plugins/tool/deploy-release/plugin.sh` and `manifest.yaml` — already v2 (#1849); no
scope.

`docs/adr/ADR-054-stage-contract.md` and `docs/adr/ADR-055-inter-stage-data-contract-v2.md`
— normative references for result shape, disposition vocabulary, and ZBUILD_STAGE_INPUTS
semantics. No changes to these files.

```acceptance
SPEC-1[guard]: deploy plugin.sh exists and deploy_agent_run is defined after source
SPEC-2[guard]: ZBUILD_DRY_RUN=1 writes deploy-result.json with verdict=deployed
SPEC-3[guard]: missing pr_url input → deploy_agent_run exits non-zero and writes verdict=error
SPEC-4[guard]: gate verdict=fail → deploy-result.json verdict=skipped (fail-closed allowlist)
SPEC-5[guard]: plugin.sh has "Role: deploy_agent" preamble comment
SPEC-6[guard]: no route_to_model call in non-comment code
SPEC-7[change]: dry-run deploy-result.json carries result_contract=2 (not schema_version=1)
SPEC-8[change]: missing gate (non-dry-run) → fail-closed returns rc=1 (not rc=2)
SPEC-9[change]: manifest provides block declares result_contract: 2
SPEC-10[change]: every terminal exit path writes v2 envelope: result_contract=2, verdict, disposition, reason all present
SPEC-11[change]: plugin.sh derives output path from ZBUILD_ARTIFACT_DIR; no state_file-derived path
SPEC-12[change]: pr_url and gate_aggregator_result resolved via ZBUILD_STAGE_INPUTS; plugin.sh constructs no pr-url.txt or gate-aggregator-result.json path in non-comment code
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
WIRING: plugins/agent/deploy/manifest.yaml
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
```

LOOP_COMPLETE
