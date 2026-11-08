# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 19 — COMPLETE

## Summary of previous iterations
- Iterations 1-13: Core implementation
- Iteration 14-17: Various fixes; 885 tests pass
- Iteration 18: ADR-006 fully amended. build/test/issue-acceptance PASS. review_lenses FAIL.

## Iteration 19: Address review_lenses findings

### Changes made:
1. runner.sh - Security finding 4: `_fsp_cycle_safe` now uses `//[^a-zA-Z0-9_]/_` pattern
2. runner.sh - Security finding 1 (line ~1775): bounds check after `_verdict_resolve_path_v` in `_runner_from_stage_preflight`
3. runner.sh - Security finding 2 (line ~3607): bounds check in cycle member skip guard
4. runner.sh - Security finding 3 (line ~3918): bounds check in dispatch-unit stage skip guard  
5. cycle-orchestrator.sh - Correctness finding 2 (line ~2410): use `jq --arg id` for cycle_id read (matches write path)
6. cycle-orchestrator.sh - Red-team finding 1 (after line 2416): cap `_start_iter` to `_CYCLE_MAX_ITER`

### Tests run after changes:
- resume-loop-state-test.sh: 11/11 PASS
- from-stage-rehydrate-test.sh: 22/22 PASS
- resume-rehydrate-test.sh: 47/47 PASS
- resume-entry-points-test.sh: 18/18 PASS
- hydrate-stage-test.sh: 25/25 PASS

### Findings answered as WRONG:
- performance-code 1: wrong — two writes required by DSITER-1, cannot be combined

### Findings answered as NOT MINE:
- red-team-code 2: not mine — artifact check in DSCMBR-1 requires _find_plugin_for_stage not in cycle-orchestrator.sh scope
- correctness-code 1: not mine — stage_statuses flat map issue requires per-iteration tracking; schema change beyond scope
- sre-code 1, 2, 3: not mine — machine-readable events require schema changes; fail-closed behavior already in dispatch loop
- performance-code 2, 3 (non-blocking): not mine — micro-optimizations, non-blocking
- scope-code 1, 2 (non-blocking): addressed inline
