# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status
Analyzing and implementing fixes from test stage findings.

## Core implementation (committed in db0e567a)
All key implementation changes:
1. `_artifact_persist_put_back` in artifact-persist.sh ✓
2. `_hydrate_put_back` → `_artifact_persist_put_back` in hydrate/plugin.sh ✓
3. hydrate-stage-test.sh redirected ✓
4. `_runner_resume_rehydrate` and `_runner_from_stage_preflight` in runner.sh ✓
5. Resume entry point calls `_runner_resume_rehydrate` ✓
6. Stale-artifact changed from warn+continue to exit 1 ✓
7. `_runner_from_stage_preflight` call before dispatch loop ✓
8. cycle-orchestrator reads current_iter unconditionally (BUG - needs guard) 
9. ADR-006 step 3.6 added ✓
10. ADR-050 §6 boundary note added ✓

## Test stage analysis (after 4ada2396 test-author commit)

### Failing tests IN SCOPE:
1. cycle-inner-iter-resets-per-outer-iter-test.sh → cycle reset bug (current_iter unconditional read)
2. cycle-member-dispatch-events-test.sh → verdict issue (unrelated? but in scope)
3. from-stage-rehydrate-test.sh SPEC-3 → "expected: 0, got: 0" (possibly already passes)
4. nested-loop-rounds-build-test.sh → cycle reset bug
5. nested-loop-rounds-test.sh → cycle reset bug
6. resume-entry-points-test.sh SPEC-13 → cycled not dispatching (grep-c bug: got "0\n0")
7. resume-loop-state-test.sh SPEC-7 → removed assertion from 4ada2396; need _ZBUILD_RESUME_ACTIVE
8. resume-rehydrate-test.sh SPEC-1 → grep-c || echo 0 bug (produces "0\n0")

### Failing tests OUT OF SCOPE (pre-existing):
- run-timed-out-test.sh - out of scope
- stop-run-on-fail-test.sh - out of scope
- write-boundary-revert-test.sh - out of scope
- stage-retry-test.sh - out of scope

## Root cause analysis

### MAIN BUG: cycle-orchestrator reads current_iter UNCONDITIONALLY
In `_cycle_orchestrator_run_body` (db0e567a), line ~2305:
```bash
_persisted_iter="$(get_state_field "$state_file" \
    ".cycle_iterations[\"$cycle_id\"].current_iter" 0 ...)"
_start_iter=$(( _persisted_iter + 1 ))
```
No guard. For nested loops (outer→inner), inner cycle picks up outer iteration's current_iter.
Fix: guard with `[[ "${_ZBUILD_RESUME_ACTIVE:-false}" == "true" ]]`.

### SPEC-7 test: needs _ZBUILD_RESUME_ACTIVE=true before cycle_orchestrator_run
The resume-loop-state test calls cycle_orchestrator_run directly (bypasses runner.sh).
Without export _ZBUILD_RESUME_ACTIVE=true, guard says "false" → _start_iter=1 → first iter=1 ≠ 2 → FAIL.

### SPEC-1 grep-c bug in resume-rehydrate-test.sh
Paths 1, 2, 3 use: `grep -c '^intake$' 2>/dev/null || echo 0`
When count=0: grep exits 1 → || echo 0 fires → result="0\n0" → assert_eq "0" "0\n0" → FAIL.
Fix: change to `wc -l | tr -d ' '` pattern.

### SPEC-13 in resume-entry-points: grep-c bug too
`grep -c '^cycled$' || echo 0` - if count=0, produces "0\n0", assert_gt "0\n0" "0" fails.
But wait: cycled SHOULD dispatch (iter=1, _cd_iter>0 → stage.start emitted).
If cycled dispatches, grep-c finds "cycled" → count=1 → exits 0 → no || echo 0 → "1" → assert_gt passes.
So either cycled doesn't dispatch, OR the grep-c bug means 0 matches.

IMPORTANT: The SPEC-13 test uses status=in_progress + no --no-resume → auto_resume.
With auto_resume, runner sets resume_mode=true and exports _ZBUILD_RESUME_ACTIVE=true (after my fix).
Then cycle_orchestrator uses guarded path: reads current_iter=0 → _start_iter=1 → dispatches cycled.
stage.start(cycled) emitted → grep-c finds it → assert_gt passes.

Wait: WITHOUT my fix (current code, unconditional read), current_iter=0 for fresh state → _start_iter=1.
SAME behavior. So cycled SHOULD dispatch with current code too.

UNLESS: the auto_resume is the issue. With status=in_progress and stage_statuses={},
the runner auto_resumes. Then it goes through resume path. Then cycle-aware dispatch loop.
No skip in cycle-aware loop. Cycle runs. Cycled dispatches.

I can't figure out why cycled wouldn't dispatch. Let me just try the fix and run the test.

## Changes needed

### 1. core/pipeline/cycle-orchestrator.sh
Replace unconditional current_iter read with guarded version:
```bash
# BEFORE:
local _persisted_iter
_persisted_iter="$(get_state_field "$state_file" \
    ".cycle_iterations[\"$cycle_id\"].current_iter" 0 2>/dev/null || echo 0)"
[[ "$_persisted_iter" =~ ^[0-9]+$ ]] || _persisted_iter=0
local _start_iter=$(( _persisted_iter + 1 ))

# AFTER:
local _start_iter=1
if [[ "${_ZBUILD_RESUME_ACTIVE:-false}" == "true" ]]; then
    local _persisted_iter
    _persisted_iter="$(get_state_field "$state_file" \
        ".cycle_iterations[\"$cycle_id\"].current_iter" 0 2>/dev/null || echo 0)"
    [[ "$_persisted_iter" =~ ^[0-9]+$ ]] || _persisted_iter=0
    _start_iter=$(( _persisted_iter + 1 ))
fi
```

### 2. core/pipeline/runner.sh
Add `export _ZBUILD_RESUME_ACTIVE=true` after _runner_resume_rehydrate:
At line ~2838, after: `_runner_resume_rehydrate "$_runner_issue" "$state_dir"`
Add: `export _ZBUILD_RESUME_ACTIVE=true`

### 3. tests/integration/resume-loop-state-test.sh
Add before cycle_orchestrator_run (line 76):
`export _ZBUILD_RESUME_ACTIVE=true`

### 4. tests/integration/resume-rehydrate-test.sh
Fix three SPEC-1 grep-c || echo 0 patterns (paths 1, 2, 3) to use wc -l | tr -d ' ':
- Path 1 (line ~139): `grep -c '^intake$' 2>/dev/null || echo 0` → `wc -l | tr -d ' '`
- Path 2 (line ~225): `grep -c '^intake$' || echo 0` → `wc -l | tr -d ' '`
- Path 3 (line ~311): `grep -c '^intake$' || echo 0` → `wc -l | tr -d ' '`

### 5. Shape-floor tests (check if needed)
Need to investigate shape-floor failures. Check if my changes affect any goldens.

## Resolved findings
- resume-loop-state SPEC-7 "no cycle.iteration.complete" assertion: REMOVED by 4ada2396, so it's dead.
- The NEW SPEC-7 "first dispatched iter is 2" needs _ZBUILD_RESUME_ACTIVE=true in test.
- cycle-member-dispatch-events: "blocking_member_failure vs fail" - need to investigate separately.
- from-stage SPEC-3 "expected: 0, got: 0": might be OK after cycle-orchestrator fix.
