# Issue #1805 acceptance notes

## Test verdict: FAIL

12 tests fail, including tests directly for issue requirements and regressions.

## Requirement analysis

### Requirements failing because their tests fail

**R-1, R-2, R-3, R-8 (trust+rehydrate completed stages, pick up at interrupted stage):**
- `resume-rehydrate-test.sh` SPEC-1 assertions fail:
  - "intake emits no stage.start (complete stage skipped)"
  - "path 2 (auto-resume): intake emits no stage.start (skipped)"
  - "path 3 (zbuild pipeline resume): intake emits no stage.start (skipped)"
- This means the dispatch loop is still dispatching completed stages on resume.

**R-4, R-10 (--from-stage rehydrates and starts at s):**
- `from-stage-rehydrate-test.sh` SPEC-3 fails:
  - "intake emits no stage.start when skipped via --from-stage"
- --from-stage is still re-dispatching the stage that should be skipped.

**R-9 (loop resume restores iter count):**
- `resume-loop-state-test.sh` SPEC-7 fails:
  - "no cycle.iteration.complete for iter=1 (iter-1 was already done before resume)"

**R-12 (all three entry points find state in runs/<run_id>/):**
- `resume-entry-points-test.sh` SPEC-13 fails (cycled stage not dispatched).

**R-15 (tests use a cycle):**
- `resume-entry-points-test.sh` SPEC-13 asserts cycled>0, got 0.

### Critical regression introduced by the change

The change to `cycle-orchestrator.sh` reads `current_iter` from persisted state for ALL
cycles, not just resumed ones. When a nested inner cycle runs in a second outer iteration,
the persisted `current_iter` from the first outer iteration causes the inner cycle to start
at iter=2 instead of resetting to iter=1. This breaks:
- `cycle-inner-iter-resets-per-outer-iter-test.sh` (T4, T5, T7, T8, T9, T10)
- `cycle-member-dispatch-events-test.sh`
- `nested-loop-rounds-build-test.sh`
- `nested-loop-rounds-test.sh`

The fix conflates "resume reads persisted iter" with "all cycle starts read persisted iter";
a fresh/inner cycle entry should ignore persisted current_iter.

### Additionally failing (regressions from stage.start emit change in _cycle_dispatch_stage)

The diff adds a stage.start emit inside `_cycle_dispatch_stage` when `_cd_iter > 0`.
This appears to double-emit stage.start for cycle members (since stage.start is already
emitted on the caller side), breaking:
- `stop-run-on-fail-test.sh` (R2: build still runs, expected 2, got 1)
- `write-boundary-revert-test.sh` (D7: first offence was retried)
- `stage-retry-test.sh` (R1: timed_out → 2 runs, got 1)
- `run-timed-out-test.sh`

### Requirements whose tests are in failing files (cannot confirm)

- R-5 (ADR-006 amended): resume-rehydrate-test.sh fails, tests for SPEC-5 not reached cleanly
- R-6 (ADR-050 §6 boundary): same file
- R-11 (--from-stage no prior output → refuse): from-stage-rehydrate-test.sh fails
- R-13 (no prior state → behaves as today): SPEC-10 claimed "already done" — cannot confirm with failing suite
- R-14 (new run never skips): SPEC-12 in resume-rehydrate-test.sh fails

### Structural checks (ADR doc changes — code-only read)

- ADR-006 step 3.6 added, names both enforcing test files, documents exit 1 for absent artifact. ✓ in diff.
- ADR-050 §6 boundary note added, references ADR-006, says "continues the same run". ✓ in diff.
- `_artifact_persist_put_back` extracted; hydrate plugin updated to call it. ✓ in diff.
But the end-to-end behavior tested by the test suite fails, so these doc changes are not sufficient.

## Verdict: FAIL

Primary failures: R-1/R-2/R-3/R-8 (SPEC-1, resume-rehydrate-test.sh), R-4/R-10 (SPEC-3,
from-stage-rehydrate-test.sh), R-9 (SPEC-7, resume-loop-state-test.sh), R-12/R-15 (SPEC-13/
SPEC-9, resume-entry-points-test.sh). The cycle-orchestrator.sh change also introduces
regressions that break unrelated cycle tests.
