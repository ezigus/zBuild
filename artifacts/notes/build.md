# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 22 — All tests pass; all fixable findings fixed

## Summary of previous iterations
- Iterations 1-13: Core implementation
- Iteration 14-17: Various fixes; 885 tests pass
- Iteration 18: ADR-006 fully amended. build/test/issue-acceptance PASS. review_lenses FAIL.
- Iteration 19-20: Addressed all review_lenses findings.
- Iteration 21: Tried to verify fixes but timed out.

## Iteration 22 findings

All 5 acceptance tests PASS in the current worktree:
- resume-rehydrate-test.sh: 49/49 PASS
- from-stage-rehydrate-test.sh: 25/25 PASS
- resume-loop-state-test.sh: 11/11 PASS
- resume-entry-points-test.sh: 18/18 PASS
- hydrate-stage-test.sh: 25/25 PASS

The review_lenses findings from the previous stage are already fixed in the current code:

**lens-correctness-code finding 1**: runner.sh:3793 adds `_update_stage_status "$state_file" "$_cyc_id" "complete"` after a cycle converges, so the cycle skip guard at 3591-3597 can find it. FIXED.

**lens-correctness-code finding 2**: cycle-orchestrator.sh:2462-2465 uses a separate `_from_stage_cycle_start` local variable (not setting `_is_resume`). The 4th param to `_cycle_iter_dispatch` is `_from_stage_start` not `_is_resume`. FIXED.

**lens-correctness-code finding 3**: cycle-orchestrator.sh:1411-1424 pre-scans all members; if ALL are "complete" from prior iter (meaning interrupted before any dispatch), switches to `_from_stage_start=true` so all members run fresh with stage.start for first. FIXED.

**lens-security-code finding 1**: runner.sh:1861-1863 reads from `_ls_issue_resolved/pipeline-state.json` (the resolved path), not from the symlink. FIXED.

**lens-sre-code finding 4**: runner.sh:1786-1789 emits `stage.verdict.stale_artifact` machine-readable event before returning 1. FIXED.

## Cannot fix:
- lens-red-team-code finding 1: assertions in acceptance test file (read-only)
- lens-scope-code finding 1/2: in acceptance test file (read-only)
- lens-performance-code finding 1: non-blocking, complex refactor
- lens-sre-code finding 1/2/3: pre-existing limitations, non-blocking
