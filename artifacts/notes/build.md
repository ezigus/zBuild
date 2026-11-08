# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 21 — fixing review_lenses findings

## Summary of previous iterations
- Iterations 1-13: Core implementation
- Iteration 14-17: Various fixes; 885 tests pass
- Iteration 18: ADR-006 fully amended. build/test/issue-acceptance PASS. review_lenses FAIL.
- Iteration 19: Addressed all review_lenses findings (security bounds checks, cycle_id fix, _start_iter cap).
- Iteration 20: build PASS, test PASS, issue-acceptance PASS, review_lenses FAIL (new run, same findings).

## Iteration 21: Fix review_lenses blocking findings

### Findings being fixed:

**lens-correctness-code finding 1** (high): Cycle dispatch-unit skip guard reads
`.stage_statuses["$_safe_cyc_id"] == "complete"` but cycles are NEVER written to
stage_statuses. Fix: add `_update_stage_status "$state_file" "$_cyc_id" "complete"` 
after cycle converges in runner.sh (before the _RUNNER_CYCLE_UNCONVERGED block at ~3784).

**lens-correctness-code finding 2** (high): `_ZBUILD_FROM_STAGE_EMIT_START=true` sets
`_is_resume=true` which triggers DSCMBR-1 skip guard. For --from-stage <cycle>, if
prior run's state has members as "complete", ALL would be skipped. Fix: use separate
`_from_stage_cycle_start=true` flag instead of overriding `_is_resume`. Pass to
_cycle_iter_dispatch as 4th param `_from_stage_start`. Emit stage.start for FIRST
member only (no skip).

**lens-correctness-code finding 3** (high): DSCMBR-1 reads flat stage_statuses which
never resets between iters. If interrupted BEFORE any member of iter N, all members
show "complete" from iter N-1 → ALL skipped. Fix: in _cycle_iter_dispatch with
_resume_first_iter=true, pre-scan all members; if ALL are "complete", switch to
_from_stage_start=true (emit stage.start for first, run all).

**lens-security-code finding 1** (non-blocking): Reads from unresolved symlink path
after readlink -f validation. Fix: use _ls_issue_resolved/pipeline-state.json at line 1855.

**lens-sre-code finding 4** (medium): _runner_from_stage_preflight emits no machine-readable
event when refusing. Fix: emit stage.verdict.stale_artifact (already registered) before return 1.

### Findings answered (not fixable by me):
- lens-red-team-code finding 1: vacuous stage.skip assertions — in acceptance test file, cannot touch
- lens-scope-code finding 1: wrong branch in from-stage test — acceptance test file, cannot touch
- lens-scope-code finding 2 (non-blocking): ADR ref in test header — acceptance test file
- lens-performance-code finding 1 (non-blocking): resume_mode not cleared — complex refactor risk
- lens-sre-code finding 1, 2, 3: machine-readable events for failures — require schema changes

### Files changed:
1. core/pipeline/runner.sh
2. core/pipeline/cycle-orchestrator.sh

### After changes, run:
- tests/integration/from-stage-rehydrate-test.sh
- tests/integration/resume-rehydrate-test.sh
- tests/integration/resume-loop-state-test.sh
- tests/integration/cycle-member-dispatch-events-test.sh
- tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
- tests/integration/nested-loop-rounds-test.sh
