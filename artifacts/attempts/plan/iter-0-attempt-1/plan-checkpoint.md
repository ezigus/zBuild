# Plan Checkpoint — issue #1845 validate plugin v2 migration

## Files read and what they told me

- `plugins/agent/validate/manifest.yaml`: already has `valid_verdicts`, `role`, `events`, `primary: true`, `provides.role`. Missing: `result_contract: 2`. Inputs already only have `id` + `required` (no path/from) — correct for v2.
- `plugins/agent/validate/plugin.sh`: constructs hardcoded paths (`$artifacts_dir/deploy-result.json`, `$artifacts_dir/validate-result.json`) from state_file. Uses `rc=2` on 3 exit paths. Result format is v1 (`schema_version:1, verdict`). No cleanup resources.
- `plugins/agent/validate/tests/validate-test.sh`: SPEC-8..13, tests v1 shape. Does not mock/set `ZBUILD_STAGE_INPUTS`.
- `core/pipeline/disposition.sh`: disposition vocabulary: `complete, unusable, timed_out, out_of_turns, interrupted, throttled, rate_limited, unavailable, misconfigured, broken`.
- `core/pipeline/input-resolve.sh`: engine exports `ZBUILD_STAGE_INPUTS` pointing to index JSON `{inputs:{<id>: <path>}}`.
- `plugins/agent/design/plugin.sh`: v2 reference — `_design_write_result` writes `{result_contract:2, verdict, disposition, reason, data:{}}`.
- `plugins/tool/lint-gate/plugin.sh`: another v2 reference — reads `ZBUILD_STAGE_INPUTS` for inputs.
- `config/templates/deployed.yaml`: validate is already in `flow:` (line 31) — no template change needed.

## Conclusions

- manifest.yaml needs only `result_contract: 2` added to `provides:`.
- plugin.sh needs: (1) v2 result shape on all exit paths, (2) `ZBUILD_STAGE_INPUTS` for input path, `ZBUILD_ARTIFACT_DIR` for output path, (3) rc=2 → rc=1.
- Router budgets: validate has no LLM calls — the router budget requirement is inapplicable.
- cleanup hook: absent is correct (no live resources). No manifest change needed.
- Tests: new specs for v2 result shape, disposition on each exit path, no-path-construction grep assertion, valid_verdicts coverage. Existing tests need `ZBUILD_STAGE_INPUTS` fixture.

## Next if stopped: emit plan JSON
