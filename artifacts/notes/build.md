# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current Status (iteration 3 of build stage)

### Changes This Iteration
Fixed two critical bugs in `core/pipeline/runner.sh`:

**Bug A** (3 integration test timeouts): Line ~2827 changed from `    ) &` to `    ) >/dev/null 2>&1 &`
- Root cause: watchdog subshell inherited runner's stdout/stderr (pipe write end when tests run inside `$(...)`)
- `sleep 20700` child of watchdog was orphaned (reparented to init) when watchdog was SIGKILL'd
- Orphaned sleep held the pipe write end open, causing `$(...)` to wait the full 480s test timeout
- Fix: redirect watchdog's fds to /dev/null so its children never inherit the pipe

**Bug B** (runner-release-exit-paths SPEC-5 regression): Added `trap ':' INT TERM` guard before kill/wait in `_runner_abort_trap`
- Root cause: `timeout 120` sends SIGTERM to PG, runner fires SIGTERM handler → `exit 1` → EXIT trap starts
- During `wait "${_RUNNER_WATCHDOG_PID:-}"`, `timeout` forwarded its own SIGTERM to the PG
- Second SIGTERM fired `_runner_signal_trap TERM` → `exit 1` inside EXIT trap → bash aborted the trap
- `_runner_dispatch_always_run` never ran → no release marker → SPEC-5 failed
- Fix: `trap ':' INT TERM` before kill/wait; restore handlers after; then dispatch always_run

### Test Results (this iteration)

PASSES:
- runner-release-exit-paths-test.sh: All 19 tests PASS (was SPEC-5 failing)
- run-timed-out-test.sh (SPEC-1): All 15 tests PASS
- run-limit-precedence-test.sh (SPEC-2/5/6): All 38 tests PASS
- run-watchdog-clean-exit-test.sh (SPEC-3): All 8 tests PASS
- resume-after-run-timeout-test.sh (SPEC-4): All 6 tests PASS
- run-open-items-test.sh: All 53 tests PASS
- runner-pipeline-end-test.sh: All 38 tests PASS
- shellcheck runner.sh: only pre-existing SC2015/SC2004 info/style notes

Integration test timeouts fixed by Bug A fix (>/dev/null 2>&1):
- core-pipeline-runner-test.sh: was TIMEOUT due to orphaned sleep
- core-pipeline-strategy-test.sh: was TIMEOUT due to orphaned sleep
- vision-admission-gate-test.sh: was TIMEOUT due to orphaned sleep

Golden file findings (5 and 6) from shape-floor:
- Consequence of test failures (_SF_FAILED_COUNT > 0 → _sf_floor_verified returns 1)
- With 0 failures, golden files auto-verified by _sf_floor_verified — no edits needed
- No golden file edits needed

### Implementation Status — COMPLETE

All files from the scope list are either:
- Already correct from prior iterations, OR
- Unchanged (no need to modify them)

Core runner.sh has both watchdog bugs fixed. All SPEC tests pass.
