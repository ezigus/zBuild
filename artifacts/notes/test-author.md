# test-author notes — issue #1805 (round 32: CMBR-1 + FRSH-2 cycle guard)

## Status: COMPLETE

## Open work this round

### 1. CMBR-1 missing from resume-loop-state-test.sh

The "Already written" script output confirms CMBR-1 is not in any file.
The review stage also passed 862 tests without it. CMBR-1 must be added
to tests/integration/resume-loop-state-test.sh.

**Approach:** Unit-test style (consistent with ITER-1 in the same file),
using `cycle_orchestrator_run` with mock `cycle_dispatch_stage`.
State set up via `zb_engine_loop_state` (rounds=2 → current_iter=2) +
jq to add `stage_statuses.build = "complete"` for the interrupted-in-iter-2 scenario.
Template: cycle-converges-iter2.yaml (has build+test stages).

The mock tracks `_CMBR1_BUILD_DISPATCHED` and `_CMBR1_TEST_DISPATCHED`.
Before fix: orchestrator doesn't skip complete members → build dispatched →
  `_CMBR1_BUILD_DISPATCHED=1` → assert 0==1 → FAILS.
After fix: orchestrator checks stage_statuses.build=complete → skips build →
  `_CMBR1_BUILD_DISPATCHED=0`, `_CMBR1_TEST_DISPATCHED=1` → PASSES.

### 2. FRSH-2 missing cycled stage.start count assertion (lens-correctness-code finding 2)

The FRSH-2 section in resume-rehydrate-test.sh only checks intake stage.start
count. The correctness lens found it doesn't assert that cycle member `cycled`
emits exactly 1 stage.start (not 2 from the missing _ZBUILD_RESUME_ACTIVE guard).

FRSH-2 is [no-code], so the test need not fail before the change. But it should
fail on BUGGY new code (missing _ZBUILD_RESUME_ACTIVE guard → cycled emits 2
stage.starts instead of 1). After proper fix (guard with _ZBUILD_RESUME_ACTIVE),
cycled emits 1 stage.start → passes.

### 3. lens-scope-code finding 2 (Path 2 passes ZBUILD_STATE_FILE)

The scope lens says Path 2 passes ZBUILD_STATE_FILE explicitly so the latest-symlink
auto-resume branch is never exercised. But Path 4 (ENTR-2) explicitly tests
the latest-symlink path WITHOUT ZBUILD_STATE_FILE set (env -u ZBUILD_STATE_FILE).
This finding was raised before Path 4 was written; Path 4 fully covers it.
No change needed to resume-entry-points-test.sh for this.

## Changes applied this round

### tests/integration/resume-loop-state-test.sh
Added [#1805/CMBR-1] section before CYCL-1:
- State: zb_engine_loop_state rounds=2 current_iter=2 + jq stage_statuses.build=complete
- Mock: cycle_dispatch_stage tracks _CMBR1_BUILD_DISPATCHED + _CMBR1_TEST_DISPATCHED
- export _ZBUILD_RESUME_ACTIVE=true; zb_stub_reports_tests test
- Call cycle_orchestrator_run "build-test"
- Assert: build NOT dispatched (0); test dispatched (1)

### tests/integration/resume-rehydrate-test.sh
Added to FRSH-2 section:
- Count stage.start events for `cycled` in the FRSH-2 runner call
- assert_eq [#1805/FRSH-2] "1" "$_frsh2_cycled_starts"
  (fails on new code with missing _ZBUILD_RESUME_ACTIVE guard → cycled emits 2)

## Findings answered

ANSWER lens-correctness-code finding 2: done — added cycled stage.start count
  assertion to FRSH-2 section in resume-rehydrate-test.sh. If the _ZBUILD_RESUME_ACTIVE
  guard is missing from _cycle_dispatch, cycled emits 2 stage.start events on a fresh
  run (1 from normal dispatch + 1 from unguarded guard); this assertion catches that.

ANSWER lens-scope-code finding 2: nothing to do — Path 4 (ENTR-2) at lines 425-554
  of resume-entry-points-test.sh already tests the latest-symlink auto-resume path
  WITHOUT ZBUILD_STATE_FILE set (env -u ZBUILD_STATE_FILE -u ZBUILD_STATE_DIR).
  Path 2 is the existing auto-resume-on-interrupted-status mechanism and correctly
  passes ZBUILD_STATE_FILE (it goes through the state-file-present detection path,
  not the latest-symlink path). These are two different auto-resume code paths.
  ENTR-2 covers the symlink path; Path 2 covers the status-detection path.
  The finding was raised before Path 4 (ENTR-2) existed.

ANSWER lens-performance-code finding 1: nothing to do (test scope) — this is a code
  correctness/perf finding about cycle_dispatch_stage emitting stage.start on every run.
  The fix is in core/pipeline/runner.sh. No test change needed beyond what FRSH-2 adds.

ANSWER lens-performance-code finding 2: nothing to do (test scope) — perf finding about
  _runner_from_stage_preflight O(N×P) plugin scans. Code fix only.

ANSWER lens-performance-code finding 3: nothing to do (test scope) — perf finding about
  get_state_field subprocesses. Code fix only.

ANSWER lens-red-team-code finding 1: nothing to do (test scope) — same as correctness
  finding 1; the FRSH-2 cycled assertion catches this at test level.

ANSWER lens-red-team-code finding 2: nothing to do (test scope) — _runner_resume_rehydrate
  silently returns 0 on restore failure. The RHYD-1/RHYD-2 tests cover the byte-identical
  and exit-1 requirements. A code fix is needed in runner.sh.

ANSWER lens-correctness-code finding 3: nothing to do (test scope) — double artifact_persist_restore
  call in --from-stage + resume_mode. Code fix in runner.sh.

ANSWER lens-correctness-design finding 1: nothing to do (test scope) — design inconsistency
  about _ZBUILD_RESUME_ACTIVE being cleared. Design/code fix.

ANSWER lens-sre-code finding 1: same as correctness finding 1; FRSH-2 cycled assertion catches it.

ANSWER lens-sre-code finding 2: nothing to do — code fix only (logging in _runner_resume_rehydrate).

ANSWER lens-sre-code finding 3: nothing to do — code fix only (_runner_from_stage_preflight logging).

ANSWER lens-sre-code finding 4: nothing to do — code fix only (readlink failure handling).

ANSWER lens-red-team-design finding 1: nothing to do — design fix for _ZBUILD_RESUME_ACTIVE.

## All SPECs and their test files (complete coverage after this round)

### tests/unit/hydrate-stage-test.sh
- DLGT-1: sentinel written by _artifact_persist_put_back override → hydrate_run called it ✓

### tests/integration/resume-rehydrate-test.sh
- RHYD-1 (3 paths): artifact-present, byte-identical, pipeline.resume before stage.start,
  no intake.stage.start ✓
- RHYD-2: exit 1 when artifact absent; no stage.start before exit ✓
- AMDR-1: ADR-006 contains step 3.6, _runner_resume_rehydrate, test names, exit 1 clause,
  before the dispatch loop, git state branch, ordering constraint ✓
- AMDR-2: ADR-050 §6 contains new run, ADR-006, continues the same run, test file citations ✓
- DSPK-1: stage k (cyc → member cycled) dispatched and emits stage.start on resume ✓
- FRSH-1: intake dispatched from stage 1; no stage.skip; no prior-run artifact in dir ✓
- SKIP-1: dispatch-unit loop emits no stage.start for complete stage with artifact present ✓
- FRSH-2: fresh run dispatches intake, no stage.skip, cycled emits exactly 1 stage.start ✓
- CYCL-1: fixture has type:cycle; pipeline was run ✓

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1: artifact-present, content from git state, pipeline.resume before dispatch,
  intake emits no stage.start, stage.start for cycled ✓
- FSTG-2: exit 1; stderr contains "has no restorable primary artifact"; no stage.start ✓
- CYCL-1: fixture has type:cycle ✓

### tests/integration/resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 ✓
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2 ✓
- ITER-1 clause 2b: nested-loop re-entry starts at iter=1 ✓
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1 ✓
- CMBR-1: build (complete in iter 2) not dispatched; test (interrupted) dispatched ← NEW

### tests/integration/resume-entry-points-test.sh
- ENTR-1 for all 3 paths: state at runs/<run_id>/; artifact restored; pipeline.resume
  precedes first stage.start; NO stage.start for intake ✓
- ENTR-2 (path 4): auto-resume via latest symlink; no ZBUILD_STATE_FILE set;
  pipeline.resume emitted and precedes first stage.start; artifact restored;
  no stage.start for intake ✓
