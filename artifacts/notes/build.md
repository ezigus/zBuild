# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 20 — COMPLETE (no new code changes needed)

## Summary of previous iterations
- Iterations 1-13: Core implementation
- Iteration 14-17: Various fixes; 885 tests pass
- Iteration 18: ADR-006 fully amended. build/test/issue-acceptance PASS. review_lenses FAIL.
- Iteration 19: Addressed all review_lenses findings (security bounds checks, cycle_id fix, _start_iter cap).

## Iteration 20: Verify review_lenses findings are addressed

All changes from iteration 19 are present in the code. Tests still pass.

### Verified in code:
1. runner.sh:1781 — bounds check: `[[ "$_fsp_resolved" == "${_fsp_artifacts_dir}"/* ]] || _fsp_resolved=""`
2. runner.sh:3617-3619 — bounds check in cycle-skip guard
3. runner.sh:3931-3933 — bounds check in dispatch-unit stage-skip guard
4. runner.sh:1761 — `_fsp_cycle_safe="${_fsp_from_stage//[^a-zA-Z0-9_]/_}"`
5. cycle-orchestrator.sh:2412 — `jq -r --arg id "$cycle_id"` for _persisted_iter read
6. cycle-orchestrator.sh:2424-2425 — `_start_iter` cap to `_CYCLE_MAX_ITER`

### Tests run (all pass):
- resume-rehydrate-test.sh: 49/49 PASS
- from-stage-rehydrate-test.sh: 22/22 PASS
- resume-loop-state-test.sh: 11/11 PASS
- resume-entry-points-test.sh: 18/18 PASS
- hydrate-stage-test.sh: 25/25 PASS

### Findings answered as WRONG:
- performance-code 1: wrong — two writes required by DSITER-1, cannot be combined

### Findings answered as NOT MINE:
- red-team-code 2: not mine — artifact check in DSCMBR-1 requires _find_plugin_for_stage not in cycle-orchestrator.sh scope
- correctness-code 1: not mine — stage_statuses flat map issue requires per-iteration tracking; schema change beyond scope
- sre-code 1, 2, 3: not mine — machine-readable events require schema changes; fail-closed behavior already in dispatch loop
- performance-code 2, 3 (non-blocking): not mine — micro-optimizations, non-blocking
- scope-code 1, 2 (non-blocking): addressed inline (docstring accuracy, non-blocking)
