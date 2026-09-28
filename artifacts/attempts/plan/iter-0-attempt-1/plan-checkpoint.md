# Plan Checkpoint

## Files read so far
- scope-manifest.md: scope is `./ ` (whole repo)
- plugins/agent/deploy/manifest.yaml: v1 manifest. Has `provides.role: deploy_agent`, `provides.events` (4 events), primary output already present. MISSING: `result_contract: 2` in provides.
- plugins/agent/deploy/plugin.sh: v1 implementation. Uses `schema_version:1`, no `disposition`, no `reason`. Constructs artifact paths in code from state_file dir. Returns rc=2 on some paths. No ZBUILD_ARTIFACT_DIR, no ZBUILD_STAGE_INPUTS.
- plugins/agent/deploy/tests/deploy-test.sh: SPEC-1..8. SPEC-7 tests schema_version=1 (will break with v2). Uses hardcoded artifacts paths, not ZBUILD_STAGE_INPUTS.
- plugins/agent/validate/manifest.yaml + plugin.sh: Reference v2 implementation. Shows pattern: `result_contract:2` in provides, `_validate_write_result` helper, ZBUILD_ARTIFACT_DIR, ZBUILD_STAGE_INPUTS.
- plugins/agent/validate/tests/validate-test.sh: SPEC-8..25 v2 tests. Reference for test structure.
- tests/unit/deploy-release-v2-result-test.sh: deploy-release tool plugin already migrated to v2.
- config/templates/deployed.yaml: deploy stage is in live flow (roles: [deploy_agent]). No template changes needed.

## Conclusions
- deploy manifest.yaml needs only: add `result_contract: 2` under provides
- deploy plugin.sh needs: add `_deploy_write_result` helper, refactor `_deploy_agent_run_inner` to use ZBUILD_ARTIFACT_DIR + ZBUILD_STAGE_INPUTS, change all results to v2 format, change rc=2 → rc=1 on all error paths, add disposition values
- deploy tests need: update SPEC-7 (schema_version=1→result_contract=2), add SPEC-9..21 for v2 contract
- No template changes: deploy_agent is already wired into deployed.yaml flow

## Disposition table
- state_file missing: broken
- pr_url missing (input): broken
- gate missing: broken (fail-closed, never ran)
- gate non-pass: complete (deliberate skip)
- deploy-release missing: broken (never ran)
- deploy-release fails: unavailable (side-effect may have partially run)
- deploy-release succeeds: complete
- dry-run: complete (deliberate non-deployment)

## What next if stopping now
Produce the plan with 3 main steps: (1) test update, (2) manifest update, (3) plugin.sh rewrite
