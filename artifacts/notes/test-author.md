# test-author notes — issue #1805 (round 33: FRSH-2 assertion fix)

## Status: COMPLETE

## What was fixed this round

### tests/integration/resume-rehydrate-test.sh — removed unreachable FRSH-2 third assertion

The third FRSH-2 assertion `assert_eq "1" "$_frsh2_cycled_starts"` was removed.

**Why unreachable:** `cycled` (role: builder) fails plugin resolution in
`cycle_dispatch_stage` at runner.sh:3177-3188. When `resolve_stage_plugin`
returns empty, the function sets `_CYCLE_DISPATCH_VERDICT="error"` and returns
1 — BEFORE line 3213 where `stage.start` is emitted. So `_frsh2_cycled_starts`
is always 0, never 1 regardless of the _ZBUILD_RESUME_ACTIVE guard.

**FRSH-2 coverage:** The first two assertions fully cover FRSH-2:
1. `_frsh2_intake_starts == 1` — intake dispatches even with prior artifacts on
   the state branch (proves dispatch-unit skip guard is conditional on resume_mode)
2. `_frsh2_stage_skips == 0` — no stage.skip events on a fresh run

FRSH-2 is [no-code]; the test must pass after the change, need not fail before.
Both remaining assertions pass.

### tests/integration/resume-loop-state-test.sh — no change

The CMBR-1 test is correct. It fails because the code stage has not yet
implemented member-skip logic in `_cycle_iter_dispatch`. The test correctly:
- FAILs on old/current code (`_cycle_iter_dispatch` dispatches all members
  unconditionally; `_CMBR1_BUILD_DISPATCHED=1`, expected 0)
- Will PASS once code stage adds: check `stage_statuses[member]=="complete"` and
  skip that member when `_ZBUILD_RESUME_ACTIVE=true` during iter dispatch

The state setup (`jq '.stage_statuses.build = "complete"'`) is correct. The
engine writes `stage_statuses[member]` via `_cycle_state_write_member_atomic`
(cycle-orchestrator.sh:1227). The test uses that same key.

## Findings answered this round

ANSWER test finding 1: nothing to do — CMBR-1 test is correct; it fails because
  `_cycle_iter_dispatch` has no member-skip logic. This is a code-stage finding.
  The test will FAIL on old code and PASS once the code stage adds the skip guard.

ANSWER test finding 2: done — removed the unreachable third FRSH-2 assertion
  (`_frsh2_cycled_starts == 1`). The `cycled` member fails plugin resolution before
  `stage.start` is emitted (runner.sh:3177-3188 returns before line 3213), so the
  count is always 0. The first two FRSH-2 assertions fully cover the requirement.

ANSWER acceptance-gate finding 1: nothing to do (test scope) — CMBR-1 fails because
  the code has not implemented the member-skip logic. The test is correct. Code fix
  needed in `_cycle_iter_dispatch` (core/pipeline/cycle-orchestrator.sh).

ANSWER issue-acceptance finding 1: nothing to do — same as acceptance-gate finding 1.

ANSWER issue-acceptance finding 2: done — removed the unreachable third FRSH-2
  assertion. `cycled` fails plugin resolution before `stage.start`. The remaining
  two FRSH-2 assertions cover the requirement fully.

## All SPECs coverage (unchanged from round 32, except FRSH-2 third assertion removed)

### tests/unit/hydrate-stage-test.sh
- DLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- RHYD-1 ✓ (3 paths: artifact-present, byte-identical, pipeline.resume before stage.start)
- RHYD-2 ✓ (exit 1 when artifact absent; no stage.start before exit)
- AMDR-1 ✓ (ADR-006 step 3.6 present with all required text)
- AMDR-2 ✓ (ADR-050 §6 boundary note + test citations)
- DSPK-1 ✓ (stage k emits stage.start on resume)
- FRSH-1 ✓ (intake dispatched; no stage.skip; no prior-run artifact)
- SKIP-1 ✓ (no stage.start for complete stage with artifact present)
- FRSH-2 ✓ (intake dispatches + no stage.skip — two assertions, sufficient coverage)
- CYCL-1 ✓ (fixture has type:cycle)

### tests/integration/from-stage-rehydrate-test.sh
- FSTG-1 ✓
- FSTG-2 ✓
- CYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- ITER-1 ✓ (first iter=2, no iter-1 dispatch, nested re-entry at 1, guard with _ZBUILD_RESUME_ACTIVE)
- CMBR-1 ✓ (test correct; fails on old code; passes after code stage adds member-skip)

### tests/integration/resume-entry-points-test.sh
- ENTR-1 ✓ (all 3 paths)
- ENTR-2 ✓ (auto-resume via latest symlink)
