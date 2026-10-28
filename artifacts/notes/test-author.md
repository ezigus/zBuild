# Test-author notes — issue #1944 (run-level wall-clock watchdog) — ROUND 23

## Status: COMPLETE

All 6 SPECs have assertions written. Round-2 checker feedback addressed.

## Round 23 fix

**Problem**: SPEC-6's ADR-025 and ADR-054 "## Enforced by cites new tests" checks
each used a single `grep -q` with an OR pattern over all four new test file names.
The assertion passed if even one of the four files was mentioned; the requirement
says "entries citing the new test files" (plural), meaning all four must be cited.

**Fix applied to `tests/unit/run-limit-precedence-test.sh`**:

1. Lines 367-376 (ADR-025 ## Enforced by check): Replaced the single OR-grep
   with a for loop checking each of the four test files individually.

2. Lines 393-402 (ADR-054 ## Enforced by check): Same — replaced single OR-grep
   with a for loop checking each of the four test files individually.

The four test files checked in each loop:
- run-timed-out-test
- run-limit-precedence-test
- run-watchdog-clean-exit-test
- resume-after-run-timeout-test

## All files — final state

### tests/integration/run-timed-out-test.sh — SPEC-1 ✓
### tests/unit/run-limit-precedence-test.sh — SPEC-2, SPEC-5, SPEC-6 ✓ (fixed)
### tests/unit/run-watchdog-clean-exit-test.sh — SPEC-3 ✓
### tests/integration/resume-after-run-timeout-test.sh — SPEC-4 ✓
### tests/unit/run-open-items-test.sh — O9 updated to 6 ✓
### tests/unit/runner-signal-rearm-test.sh — [SPEC-5] awk pattern narrowed ✓

## Existing checks verified

1. run-open-items-test.sh [O9]: count is 6 ✓
2. runner-signal-rearm-test.sh [SPEC-5]: awk pattern uses `/trap '.*' TERM$/` ✓

## LOOP_COMPLETE
