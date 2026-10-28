# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 15

## Status: COMPLETE

All 6 SPECs have assertions written. All test files verified on disk.

## What changed in round 15

### tests/integration/run-timed-out-test.sh — P2 sentinel fix (SPEC-1)

The checker found: P2 had no assertion that fast-two never started.
The existing assertions (fast-one=complete, status=timed_out) passed equally
whether the watchdog fired during fast-two's 30s sleep OR in the idle window.

**Fix applied**:
1. Changed fast-one plugin from immediate-return to `sleep 2` — this consumes 2s
   of the 3s limit, leaving a ~1s idle window after fast-one completes before the
   watchdog fires at t≈3s.
2. Added assertion: fast-two sentinel file is ABSENT after the run.

**Falsifiability**:
- OLD code (no watchdog): fast-one sleeps 2s, fast-two starts at ~t=2s, writes
  sentinel immediately, outer timeout 25 kills at t=25s. Sentinel IS present →
  new assertion FAILS on old code ✓
- NEW code (with watchdog at t=3s): fast-one finishes at t≈2s. Engine is in idle
  window (~1s). Watchdog fires before engine can dispatch fast-two. Sentinel ABSENT
  → assertion PASSES ✓

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 (complete, P2 fixed in round 15)
- P2 now: fast-one sleeps 2s, max_run_s=3, fast-two sentinel absent assertion added

### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 (complete, unchanged)

### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 (complete, unchanged)

### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 (complete, unchanged)

### tests/unit/run-open-items-test.sh — O9 updated to 6 (done in round 13)

### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] fixed in round 14

## LOOP_COMPLETE
