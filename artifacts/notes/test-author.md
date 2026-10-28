# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 22

## Status: COMPLETE

All 6 SPECs have assertions written. All test files verified on disk.

## Round 21 analysis

Re-invoked after test stage verdict=fail. Verified all test files on disk.
The failing test from the test stage (runner-release-exit-paths-test.sh [SPEC-5])
carries a bare [SPEC-5] tag (no issue number) and is NOT in my named testfiles
or existing-checks list. All shape floor findings are also outside my scope.
All 6 SPEC assertions and 2 existing-check updates remain correct on disk.

### Failing tests from test stage — both outside my scope

**Finding 1**: `tests/integration/runner-release-exit-paths-test.sh` ✗ [SPEC-5]
- Bare [SPEC-5] tag, no issue number — NOT my existing-checks list
- Failure: marker empty, meaning cleanup hooks did not run on the "external hard kill" exit path
- Root cause: likely the new `trap ':' INT TERM` guard in `_runner_abort_trap` interfering
  with the SIGTERM→cleanup path when the runner is killed externally
- NOT mine to fix — code-change stage responsibility

**Finding 2**: `tests/integration/sigterm-aborts-pipeline-test.sh` timed out (480s)
- Not in my named testfiles or existing-checks list
- NOT mine to fix — code-change stage responsibility

**Shape floor findings 3 & 4**: golden files
- tests/golden/full-pipeline/event-sequence.golden and tests/golden/parity/event-sequence.golden
- Not in my named testfiles list
- NOT mine to fix — code-change stage responsibility

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 ✓
- P1: slow stage, status=timed_out in pipeline-state.json; pipeline.end event fields
- P2: fast-one=5s, max_run_s=6, fast-two=60s; elapsed ≤ 20s + fast-one=complete
      proves global wall-clock timer (accounts for TERM+10s+overhead ≈ 18s total)
- P3: TERM-ignore stage dead within TERM+10s+buffer=17s
- P4: always_run release + persist markers prove both ran on timed-out exit path

### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 ✓
### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 ✓
### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 ✓
### tests/unit/run-open-items-test.sh — O9 updated to 6 ✓
### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] awk pattern narrowed to /trap '.*' TERM$/ ✓

## Existing checks verified

1. run-open-items-test.sh [O9]: count is 6 (line 189 asserts "6") ✓
2. runner-signal-rearm-test.sh [SPEC-5]: awk pattern at line 92 uses `/trap '.*' TERM$/`
   (shell-escaped as `/trap '"'"'.*'"'"' TERM$/`), correctly skipping `trap ':' INT TERM` ✓

## What remains (not mine)

- runner-release-exit-paths-test.sh [SPEC-5] — bare tag, code-change stage must fix
  the implementation so the TERM→cleanup path works correctly with the new watchdog
- sigterm-aborts-pipeline-test.sh — timeout, code-change stage responsibility
- golden files — code-change stage responsibility

## LOOP_COMPLETE
