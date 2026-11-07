# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 13 — COMPLETE

## Changes made in iteration 13

### core/state/artifact-persist.sh
- Added dotdot traversal check: `[[ "$rel" == *../* || "$rel" == ..* ]] && continue`
  Addresses lens-security-code finding 1.

### core/pipeline/cycle-orchestrator.sh
- Added `_cycle_state_jq_write_iter_start` + `_cycle_state_write_iter_start` functions
  to write `current_iter=N` BEFORE dispatch (correctness-1 fix)
- Added `_cycle_state_write_iter_start "$state_file" "$cycle_id" "$iter" || true`
  call before `_cycle_iter_dispatch` in the main iteration loop
- Fixed DSCMBR-1: added `_resume_first_iter=false` after emitting stage.start for
  the first non-complete member, so subsequent non-complete members are dispatched
  normally without spurious stage.start (red-team-2 fix)

### core/pipeline/runner.sh
- Added `export _ZBUILD_RESUME_ACTIVE=false` in the `if ! $resume_mode` block
  to clear any inherited value from a parent resume run (red-team-1/sre-1 fix)
- Added stale-artifact check in `cycle:*` resume skip arm: iterate cycle members,
  check each member's primary artifact, exit 1 if absent (red-team-3/sre-2 fix)
- Replaced `$(_verdict_primary_output_path ...)` with `_verdict_primary_output_path_v`
  and `$(_verdict_resolve_path ...)` with `_verdict_resolve_path_v` in both the
  dispatch loop stage:* arm and `_runner_from_stage_preflight` (performance-1,2 fix)
- Added containment check to latest-symlink issue-discovery block using readlink -f
  to verify symlink target is within state root (red-team-5 fix)

## Findings answered (not code changes)

### scope-1: DSENTR-2 latest-symlink branch unreachable
FALSE. PATH 4 of resume-entry-points-test.sh uses `env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR`,
which routes through the new latest-symlink elif. Test passes.

### correctness-2 and correctness-3: Test fixture uses `rounds=2` wrong
After the correctness-1 fix, `current_iter=2` IS what the engine produces for mid-iter-2
interruption (written at iter-2 start via `_cycle_state_write_iter_start`). Test is now correct.

### correctness-4: parallel:*/map:* arms lack skip guard
Out of scope for #1805.

### red-team-4: Double git ops on --resume --from-stage
I/O efficiency issue; correctness is handled by no-clobber guard. Out of scope.

### red-team-6 (low): pipeline.skip_to_stage on --from-stage --resume
No acceptance test asserts absence of this event. Low finding. Out of scope.

### performance-3,4 (low): jq subshells in state file reads
Lower priority optimization. Out of scope.

### sre-3,4 (low): no machine-readable event on restore fail; double git ops
Lower priority. Out of scope.

## Test results after iteration 13
- resume-rehydrate-test.sh: 47/47 ✓
- from-stage-rehydrate-test.sh: 12/12 ✓
- resume-loop-state-test.sh: 10/10 ✓
- resume-entry-points-test.sh: 18/18 ✓
- hydrate-stage-test.sh: 25/25 ✓
- cycle-member-dispatch-events-test.sh: 24/24 ✓
- cycle-inner-iter-resets-per-outer-iter-test.sh: 15/15 ✓
- nested-loop-rounds-test.sh: 11/11 ✓
- pipeline-resume-test.sh: 23/23 ✓
- sigpipe-antipattern-guard-test.sh: 9/9 ✓
