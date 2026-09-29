# Plan stage checkpoint — issue #1835 (refined)

## Files read (this session)
- manifest.yaml: goal_string is source:external required:false; plan.json primary:true; config.router has retries:1 retry_on_exhaustion:1 but no timeout_s/max_turns; valid_verdicts: []
- plugin.sh lines 98-131: plan_run reads ZBUILD_GOAL then intake.md, constructs scope_manifest as hardcoded path, returns 2 on no-state-file (line 105) and no-goal (line 123)
- plugin.sh lines 820-849: scope_too_large path: emits events, returns 10 (no plan.json written)
- plugin.sh lines 852-929: error path returns 1 (no plan.json written); success writes plan.json then returns 0
- runner.sh lines 3506-3522: leaf path rc=10 branch for scope_too_large
- verdict.sh lines 391-414: reads verdict/reason/disposition from the resolved primary file; checks all three fields non-empty for v2

## KEY DIRECTION (previous run failed on these)
1. intake_goal input (not ZBUILD_GOAL): manifest replaces goal_string with id:intake_goal required:true; plugin reads from ZBUILD_STAGE_INPUTS like scope_manifest
2. ONE result file = plan.json: v2 fields (result_contract:2, verdict, disposition, reason) merged INTO plan.json on EVERY exit path including success
3. No engine changes except: delete runner.sh leaf path rc=10 branch (lines 3506-3522)

## Conclusions
- manifest: add result_contract:2, valid_verdicts:[pass,error], timeout_s/max_turns; replace goal_string with intake_goal; retries/retry_on_exhaustion stay (issue says "goes or PR records why")
- plugin.sh: _plan_write_minimal helper writes {result_contract:2, verdict, disposition, reason} to plan.json on failure paths; success merges v2 fields into plan_json before atomic_write; ZBUILD_STAGE_INPUTS for both scope_manifest and intake_goal; return 2→1; return 10→1 with out_of_turns
- runner.sh: delete lines 3506-3522 (leaf rc=10 branch only)
- tests: test all exit paths + manifest fields + runner_read_stage_verdict on success

## Next if stopped
Write tests first (RED), then manifest, then plugin.sh, then runner.sh.
