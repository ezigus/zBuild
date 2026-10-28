# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 17

## Status: COMPLETE

All 6 SPECs have assertions written. All test files verified on disk.

## What changed in round 17

### tests/integration/run-timed-out-test.sh — P2 redesign (SPEC-1)

**Problem identified in round 2 check**: The elapsed-time bound (≤ 8s) in P2
with fast-one=1s and max_run_s=2s could not distinguish a global wall-clock
watchdog from a per-stage timer that resets at each stage start:
- Global timer fires at t=2s → elapsed≈2s ≤ 8s → PASSES
- Per-stage timer fires at 1+2=3s → elapsed≈3s ≤ 8s → ALSO PASSES
Both pass the ≤ 8s bound, so the test cannot prove the timer is global.

**Fix applied** (round 17):
Increased fast-one and max_run_s to create clear separation:
- `fast-one: sleep 5` (was `sleep 1`)
- `ZBUILD_MAX_RUN_S=6` (was `ZBUILD_MAX_RUN_S=2`)
- elapsed bound: `≤ 10s` (was `≤ 8s`)

**How it now distinguishes global from per-stage**:
- Global timer fires at absolute t=6s → elapsed≈6-8s ≤ 10s → PASSES
- Per-stage reset fires at fast-two-start + 6s = ~5+6 = ~11s → elapsed≈11s > 10s → FAILS

The two checks together prove a global timer:
1. fast-one completed (status=complete) → watchdog fired after t≈5s
2. elapsed ≤ 10s → watchdog fired before t=10s
3. Window (5s, 10s] → only global timer at t=6s qualifies; per-stage at t=11s does not

**Falsifiability**:
- OLD code (no watchdog): outer timeout at 25s → elapsed≈25s > 10s → FAILS ✓
- Per-stage reset (wrong implementation): elapsed≈11s > 10s → FAILS ✓
- NEW code (global watchdog at t=6s): elapsed≈6-8s ≤ 10s → PASSES ✓

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 (complete, P2 re-redesigned in round 17)
- P1: slow stage, status=timed_out in pipeline-state.json; pipeline.end event fields
- P2: fast-one=5s, max_run_s=6, fast-two=60s; elapsed ≤ 10s + fast-one=complete
      proves global wall-clock timer (not per-stage reset)
- P3: TERM-ignore stage dead within TERM+10s+buffer=17s
- P4: always_run release + persist markers prove both ran on timed-out exit path

### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 (complete, unchanged)
### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 (complete, unchanged)
### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 (complete, unchanged)
### tests/unit/run-open-items-test.sh — O9 updated to 6 (done in round 13)
### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] fixed in round 14

## LOOP_COMPLETE
