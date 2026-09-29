# Plan stage checkpoint — issue #1835

## Files read
- plugins/agent/plan/manifest.yaml (113 lines) — provides.role: planner, provides.events declared, valid_verdicts: [], result_contract absent; plan.json output has primary: true; config.router has retries:1 and retry_on_exhaustion:1 but NO timeout_s/max_turns; inputs: scope_manifest (required:true, no source:), goal_string (source: external)
- plugins/agent/plan/plugin.sh (932 lines) — plan_run at line 98: constructs scope_manifest as "$state_dir/scope-manifest.md" at line 111 (no ZBUILD_STAGE_INPUTS check); return 2 at lines 105 and 123 for missing state_file/goal_text; no ZBUILD_STAGE_INPUTS check at all; no plan-result.json write; no v2 result file on any path; error path at lines 856-861 emits plugin.result verdict=error then returns 1; scope_too_large at line 849 returns 10 (no result file); success at lines 917-922 emits plugin.result verdict=pass then returns 0
- plugins/agent/design/plugin.sh — reference ZBUILD_STAGE_INPUTS pattern at lines 143-148: checks ZBUILD_STAGE_INPUTS, reads scope_manifest from it, falls back to constructed path

## Conclusions
1. manifest.yaml needs: result_contract: 2 in provides; valid_verdicts: [pass, error]; add timeout_s: 300, max_turns: 45 to config.router; new plan-result output entry; plan.json primary: true already present
2. plugin.sh needs: _plan_write_result helper (~20 lines); wire it on 5 exit paths (success, error, scope_too_large, missing-state-file, missing-goal); add ZBUILD_STAGE_INPUTS check for scope_manifest at line 111; change return 2 → return 1 at lines 105 and 123
3. tests/plan-test.sh needs: new tests for v2 result file on all 3 outcomes (pass/error/out_of_turns); manifest valid_verdicts assertion; no-path-construction grep test; router budget fields test

## Next if stopped
Write tests first (red step), then manifest, then plugin.sh implementation.
