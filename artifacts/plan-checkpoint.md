# Plan Checkpoint — issue #1845 validate plugin v2 migration

## Files read and what they told me

- `plugins/agent/validate/manifest.yaml`: already has `valid_verdicts`, `role`, `events`, `primary: true`, `provides.role`. Missing: `result_contract: 2`. Inputs already only have `id` + `required` (no path/from) — correct for v2. Outputs declare `${artifact_dir}/validate-result.json` path — this is used by the engine, but plugin.sh constructs paths independently from `$artifacts_dir` (needs to switch to `ZBUILD_ARTIFACT_DIR`).
- `plugins/agent/validate/plugin.sh`: constructs hardcoded paths (`$artifacts_dir/deploy-result.json`, `$artifacts_dir/validate-result.json`) from state_file. Uses `return 2` on 3 exit paths. Result format is v1 (`schema_version:1, verdict`). No cleanup resources. `validate_agent_run` also uses `return 2` when no state_file.
- `plugins/agent/validate/tests/validate-test.sh`: SPEC-8..13, tests v1 shape. Does not set `ZBUILD_STAGE_INPUTS`. Tests use `$_run*/artifacts/` paths — these will need updating when plugin switches to `ZBUILD_STAGE_INPUTS`/`ZBUILD_ARTIFACT_DIR`.
- `plugins/agent/design/plugin.sh`: v2 reference — `_design_write_result` writes `{result_contract:2, verdict, disposition, reason, data:{}}`.
- `plugins/tool/lint-gate/plugin.sh`: reads `ZBUILD_STAGE_INPUTS` via `jq -r '.inputs.test_results // empty' "$ZBUILD_STAGE_INPUTS"`.

## Conclusions

- manifest.yaml needs only `result_contract: 2` added to `provides:`.
- plugin.sh needs: (1) v2 result shape on all exit paths via `_validate_write_result` helper, (2) `ZBUILD_STAGE_INPUTS` for deploy_result input path, `ZBUILD_ARTIFACT_DIR` for output path, (3) `return 2` → `return 1` everywhere.
- Tests: add SPEC-14..18 for v2 contract; update SPEC-9/11/12 to export `ZBUILD_STAGE_INPUTS` and `ZBUILD_ARTIFACT_DIR`.
- Router budgets: validate has no LLM calls — inapplicable.
- cleanup hook: absent is correct.
- primary: true output: already declared.
- Template: validate already in flow:.

## Plan is ready to emit.
