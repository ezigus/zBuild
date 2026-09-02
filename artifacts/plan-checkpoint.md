## Checkpoint — build plugin v2 migration plan (iteration 2)

### Files read
- plugins/agent/build/plugin.sh lines 60-145: lines 78-79 still have fallback path constructions (`$state_dir/scope-manifest.md`, `$artifacts_dir/plan.json`). Return 2 at line 114 is already fixed to return 1. ZBUILD_STAGE_INPUTS block at 82-88 overrides these when set.
- plugins/agent/build/tests/build-test.sh lines 960-1065: SPEC-15 (rc=1 for empty args) and SPEC-16 (design.md from ZBUILD_STAGE_INPUTS) already added in commit 98b2441. No grep assertion test for "no path constructions" exists yet.
- plugins/agent/build/manifest.yaml: inputs declared as scope_manifest and plan; outputs as diff_patch and build_summary with ${artifact_dir} paths.

### Conclusions
- fdaa186 + 98b2441 completed: manifest v2 fields, unconditional disposition/reason, ZBUILD_STAGE_INPUTS path resolution, rc=1 fixes for SIGINT/missing-plan/empty-args, SPEC-1 through SPEC-16 tests.
- Two items remain: (1) lines 78-79 in plugin.sh still construct fallback input paths (scope-manifest.md, plan.json) — violates "no artifact paths in code"; (2) no SPEC-17 grep assertion test proving zero path constructions.
- SPEC-13 (state_file absent) exits before path resolution — safe to remove fallback. SPEC-6/7 sets ZBUILD_STAGE_INPUTS — safe to require it.
- Output paths (lines 93-94: diff.patch, build-summary.json) are this plugin's own outputs, not inputs from other stages — acceptable.

### If stopping now
Add SPEC-17 test (grep plugin.sh for scope-manifest.md, assert 0), then remove lines 78-79 from build_stage_run (replace with error+return 1 if ZBUILD_STAGE_INPUTS absent), then run npm test.
