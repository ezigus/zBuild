## Checkpoint — build plugin v2 migration plan

### Files read
- plugins/agent/build/manifest.yaml: result_contract:2, valid_verdicts, router budget, primary:true, provides.role/events, cleanup hook — all present
- plugins/agent/build/plugin.sh: 
  - ZBUILD_STAGE_INPUTS branch present (lines 82–88, overrides scope_manifest + plan_json_path)
  - Fallback path constructions at lines 78–79 still exist (`$state_dir/scope-manifest.md`, `$artifacts_dir/plan.json`)
  - return 2 at line 114 (arg-validation in _build_stage_run_inner) — violates rc∈{0,1}
  - Missing plan.json → rc=1 with disposition:broken (fixed)
  - SIGINT (rc=130) → rc=1 with disposition:interrupted (fixed)
- plugins/agent/build/lib/summary.sh: all branches set build_disposition and build_reason unconditionally; jq output includes disposition+reason always
- plugins/agent/build/tests/build-test.sh: 982 lines; SPEC-1 through SPEC-14 present, including SIGINT (SPEC-14), missing plan (SPEC-5), ZBUILD_STAGE_INPUTS (SPEC-6/7), result_contract:2 (SPEC-8), scope_violation (SPEC-3/4)

### Conclusions
- The migration commit (fdaa186) completed: manifest v2 fields, unconditional disposition/reason in summary, ZBUILD_STAGE_INPUTS path resolution, SIGINT+missing-plan rc=1, most tests
- Two violations remain: (1) return 2 at plugin.sh:114; (2) fallback path constructions at lines 78–79 — acceptance says "assert by grep: no path constructions in plugin.sh"
- No test yet for "grep plugin.sh shows no artifact path constructions"
- No test yet for _build_stage_run_inner missing-args returning rc=1 (not rc=2)

### If stopping now
Write tests for the two remaining gaps (grep assertion + return 2 → rc=1), fix return 2 at line 114, remove fallback paths at lines 78–79 from build_stage_run (error if ZBUILD_STAGE_INPUTS absent), then run npm test.
