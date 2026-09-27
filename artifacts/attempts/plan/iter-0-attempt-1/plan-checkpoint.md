# Plan Checkpoint — issue #1845 validate plugin v2 migration

## Files read and what they told me

- `plugins/agent/validate/manifest.yaml`: already has `valid_verdicts`, `role`, `events`, `primary: true`. Missing: `result_contract: 2` in provides block. Inputs have only `id`+`required` (no path/from) — correct for v2. Outputs declare `${artifact_dir}/validate-result.json` path.
- `plugins/agent/validate/plugin.sh`: 119 lines. Constructs hardcoded paths from `$state_dir/artifacts/` — both deploy_result_in and validate_result_out. Uses `return 2` on 4 paths: L43 (no-state-file in validate_agent_run), L67 (missing-input), L115 (missing-hc-plugin). Also returns `"$hc_rc"` for probe failures. v1 result shape throughout (`schema_version:1`). No cleanup resources held.
- `plugins/agent/validate/tests/validate-test.sh`: 172 lines, SPEC-8..13. Tests use `$_runN/artifacts/` paths (state_dir-derived). No ZBUILD_STAGE_INPUTS set. Tests need updating: SPEC-9/11/12 need ZBUILD_STAGE_INPUTS fixture + ZBUILD_ARTIFACT_DIR. SPEC-14..18 are new.
- `plugins/agent/design/plugin.sh`: v2 reference — `_design_write_result` writes `{result_contract:2, verdict, disposition, reason, data:{}}` via atomic_write.

## Conclusions

- manifest.yaml: add `result_contract: 2` to provides block only.
- plugin.sh: (1) add `_validate_write_result` helper, (2) switch to ZBUILD_STAGE_INPUTS for input path, ZBUILD_ARTIFACT_DIR for output, (3) all `return 2` → `return 1`, (4) all result writes → v2 shape via helper with dispositions: missing-input=broken, dry-run=complete, healthy=complete, failed-probe=complete, missing-hc-plugin=broken. `return "$hc_rc"` stays as-is for fail-closed.
- Tests: add SPEC-14..18, update SPEC-9/11/12 fixtures for ZBUILD_STAGE_INPUTS/ZBUILD_ARTIFACT_DIR.
- cleanup hook absent is correct. primary:true already declared. validate already in template flow.

## Plan emitted.
