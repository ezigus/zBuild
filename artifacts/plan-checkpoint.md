# Plan stage checkpoint — issue #1835

## Files read
- plugins/agent/plan/manifest.yaml (113 lines) — provides.role: planner, provides.events declared, valid_verdicts: [], result_contract absent; plan.json output has primary: true; config.router has retries:1 and retry_on_exhaustion:1 but NO timeout_s/max_turns; inputs: scope_manifest (required:true, no source:), goal_string (source: external); no plan-result output declared
- plugins/agent/plan/plugin.sh (932 lines) — plan_run at line 98: constructs scope_manifest as "$state_dir/scope-manifest.md" at line 111 (no ZBUILD_STAGE_INPUTS check); return 2 at lines 105 and 123 for missing state_file/goal_text; no plan-result.json write anywhere; error path at lines 856-861 emits plugin.result verdict=error then returns 1; scope_too_large at line 849 returns 10 (no result file); success at lines 917-929 emits plugin.result verdict=pass then returns 0
- plugins/tool/teardown/plugin.sh — v2 reference: writes result_contract:2, verdict, disposition via inline printf heredoc around line 255
- plugins/tool/teardown/manifest.yaml — v2 reference: result_contract: 2 under provides, valid_verdicts: [complete, degraded]
- tests/plan-test.sh: 843 lines currently

## Conclusions
1. manifest.yaml needs: result_contract: 2 in provides; valid_verdicts: [pass, error]; add timeout_s: 300, max_turns: 45 to config.router; new plan-result output entry (id: plan_result, path: ${artifact_dir}/plan-result.json); plan.json primary: true already present; role+events already present
2. plugin.sh needs: _plan_write_result helper (~20 lines); wire on 5 exit paths (success ~929, error ~861, scope_too_large ~849, missing-state-file ~105, missing-goal ~123); ZBUILD_STAGE_INPUTS check for scope_manifest at line 111; return 2 → return 1 at lines 105 and 123
3. tests/plan-test.sh needs: new tests for v2 result file on pass/error/scope_too_large paths; manifest valid_verdicts assertion; router budget fields test; no-path-construction grep test

## Next if stopped
Write tests first (red step), then manifest, then plugin.sh.
