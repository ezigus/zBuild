# Plan Checkpoint

## Files read so far
- plugins/agent/deploy/manifest.yaml: v1. Has primary:true output, provides.role, provides.events (4), valid_verdicts, tier_default:T2. MISSING result_contract:2 in provides.
- plugins/agent/deploy/plugin.sh: v1. Uses schema_version:1, rc=2 on 3 paths (state_file missing, pr_url missing, gate missing). Constructs paths from state_file dir. No ZBUILD_ARTIFACT_DIR, no ZBUILD_STAGE_INPUTS. On deploy-release failure: returns $? (not clamped to 1).
- plugins/agent/deploy/tests/deploy-test.sh: SPEC-1..8. SPEC-7 checks schema_version=1 (needs update to result_contract=2). SPEC-8 checks rc=2 for missing gate (needs update to rc=1). Tests use _make_state helper that creates state.json + artifacts dir; tests call _deploy_agent_run_inner directly with state_file path. No ZBUILD_ARTIFACT_DIR or ZBUILD_STAGE_INPUTS set in test setup.
- plugins/agent/validate/plugin.sh: Reference v2 pattern: _validate_write_result helper, ZBUILD_ARTIFACT_DIR for all writes, ZBUILD_STAGE_INPUTS for input path resolution.
- config/templates/deployed.yaml (from checkpoint): deploy is in live flow. No template changes needed.

## Conclusions
1. manifest.yaml: add `result_contract: 2` under provides
2. plugin.sh: add _deploy_write_result helper; update deploy_agent_run (state_file missing→rc=1, write to ZBUILD_ARTIFACT_DIR); rewrite _deploy_agent_run_inner: use ZBUILD_ARTIFACT_DIR for all writes, ZBUILD_STAGE_INPUTS for input resolution, remove 3 path-construction vars, all error returns→rc=1, add disposition to all _deploy_write_result calls, add v2 result on success path
3. tests: update SPEC-7 (schema_version=1→result_contract=2), SPEC-8 (rc=2→rc=1), update all test helpers to set ZBUILD_ARTIFACT_DIR + ZBUILD_STAGE_INPUTS; add SPEC-9..21

## Disposition table
- state_file missing: broken, rc=1
- pr_url missing (via ZBUILD_STAGE_INPUTS): broken, rc=1
- gate missing (via ZBUILD_STAGE_INPUTS): broken, rc=1
- gate non-pass: complete (deliberate skip), rc=0
- deploy-release missing: broken, rc=1
- deploy-release fails (non-zero rc): unavailable, rc=1
- deploy-release succeeds: complete, rc=0
- dry-run: complete, rc=0

## What to produce: 3-step plan
1. (tests RED) deploy-test.sh: update SPEC-7, SPEC-8; update _make_state helper to set ZBUILD_ARTIFACT_DIR+ZBUILD_STAGE_INPUTS; add SPEC-9..21
2. (manifest) manifest.yaml: add result_contract:2 under provides
3. (plugin.sh) add helper, rewrite run+inner, fix rc=2→rc=1, use ZBUILD_ARTIFACT_DIR+ZBUILD_STAGE_INPUTS
