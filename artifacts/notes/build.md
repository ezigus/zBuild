# Build notes — issue #1801

## State at start of this call

Previous test stage found 3 failures:
1. runner-job-control-abort-test.sh — "flag-on: monitor mode ON in runner shell" (got: dash=huB)
2. runner-release-exit-paths-test.sh — SPEC-6b (pid still alive 5s after runner returned)
3. stage-timeout-dispatch-test.sh — SPEC-10 (kill -KILL still present)

## What I found

Running tests on current tree at start of this iteration:
- stage-timeout-dispatch-test.sh: ALL PASS (SPEC-10 already fixed in prior iteration)
- runner-job-control-abort-test.sh: ALL PASS (flag-on check already fixed in prior iteration)
- runner-release-exit-paths-test.sh: SPEC-5 FAILS with empty marker, SPEC-6b PASSES

## Root cause of SPEC-5 failure (refined analysis)

The initial fix (adding `trap "" TERM` before `_runner_signal_trap TERM`) was WRONG because
`trap "" TERM` was placed AFTER the zbuild_pg_kill calls, which contain `sleep 0.1` loops.

The actual bug is BASH TRAP RE-ENTRY. In bash, when a foreground command (like `sleep 0.1`)
is running inside a trap body, and a second TERM signal arrives, bash delivers the second TERM
when `sleep 0.1` exits - EVEN THOUGH we're already in a TERM trap handler. This re-enters
the trap body.

With SPEC-5's process-group kill:
1. TERM sent to process group: both runner and `timeout 120` receive TERM simultaneously
2. Runner's lifecycle TERM trap fires (first instance)
3. `zbuild_pg_kill "$_lc_hook_pid" 1` runs: internally loops `sleep 0.1` up to 10 times
4. During one of these sleeps, `timeout 120` (which also received TERM) sends TERM to runner
5. When `sleep 0.1` exits, bash delivers the second TERM: TRAP RE-ENTRY!
6. Second trap instance runs: kills hook/wd, `_runner_signal_trap TERM` → `exit 1` → EXIT trap starts
7. EXIT trap: `_runner_dispatch_always_run` starts cleanup
8. First trap instance resumes: `_runner_signal_trap TERM` → `exit 1` INSIDE the EXIT trap
9. `exit 1` inside EXIT trap = immediate termination, aborting cleanup
10. RELEASE_MARKER is never written

Confirmed by experiment: bash DOES re-enter TERM traps when a second TERM arrives during
a foreground command (`sleep`) inside the first trap body.

## Fix applied (revised)

Move `trap "" TERM` to the VERY BEGINNING of both trap bodies (subshell and main-shell).
This prevents any re-entry: the first thing the trap does is ignore further TERMs.

Change: lifecycle.sh TERM trap for both subshell and main-shell cases:
- Before (subshell): `trap 'zbuild_pg_kill ...; exit 143' TERM`
- After  (subshell): `trap 'trap "" TERM; zbuild_pg_kill ...; exit 143' TERM`
- Before (main):     `trap 'zbuild_pg_kill ...; zbuild_pg_kill ...; trap "" TERM; ...' TERM`
- After  (main):     `trap 'trap "" TERM; zbuild_pg_kill ...; zbuild_pg_kill ...; ...' TERM`

## Why this doesn't break SPEC-6b

SPEC-6b: cleanup hook spawns TERM-ignoring child, calls `wait`. Always_run watchdog sends
TERM to plugin_hook_call's subshell group. With `trap "" TERM` at the start of the subshell
trap:
1. TERM arrives, `trap "" TERM` fires immediately (prevents re-entry)
2. `zbuild_pg_kill "$_lc_hook_pid" 1` - sends TERM to hook group, then KILL after 1s
3. The TERM-ignoring child is in the same group (set +m in hook subshell), gets KILLed
4. `exit 143`

SPEC-6b should still pass because zbuild_pg_kill sends KILL (which can't be ignored).

## Tests verified this iteration

1. stage-timeout-dispatch-test.sh: ALL PASS (confirmed after fix)
2. runner-job-control-abort-test.sh: ALL PASS (confirmed after fix)
3. runner-release-exit-paths-test.sh: RUNNING IN BACKGROUND (waiting for result)
