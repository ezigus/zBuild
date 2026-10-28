# Build notes — issue #1944: run-level wall-clock limit with watchdog

## Current Status (iteration 4 of build stage)

### Summary of All Bugs and Their Status

**Bug A** (3 integration test timeouts — orphaned sleep holds pipe write end):
- Committed in 741c8466: partial fix `>/dev/null 2>&1 &` (fds 1 and 2 closed)
- Still needed: `{_RUNNER_ERR_FD}>&-` to close the high-numbered fd that also points to the pipe
- APPLIED IN WORKING TREE (uncommitted): line 2827 changed from `) >/dev/null 2>&1 &` to `) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`

**Bug B** (double-SIGTERM aborts EXIT trap → always_run never runs):
- Committed in 741c8466: `trap ':' INT TERM` guard + trap restore in `_runner_abort_trap`
- COMPLETE

**Bug C** (SPEC-5 in runner-signal-rearm-test.sh — awk matches wrong line):
- The `trap ':' INT TERM` guard added by Bug B fix is inside `_runner_abort_trap` in main()
- The old awk pattern `/trap .* TERM$/` found this line first (before the startup install at 2751)
- grep -oE couldn't extract from it → `_startup_term` empty → SPEC-5 failed
- APPLIED IN WORKING TREE (uncommitted): runner-signal-rearm-test.sh line 92 awk changed from `/trap .* TERM$/` to `/trap '.*' TERM$/` (requires single-quoted handler)
- Test confirmed passing after change

### Findings from Previous Test Stage

1. core-pipeline-runner-test.sh TIMEOUT → fixed by Bug A completion
2. core-pipeline-strategy-test.sh TIMEOUT → fixed by Bug A completion
3. runner-signal-rearm-test.sh SPEC-5 → fixed by Bug C, VERIFIED NOT REPRODUCED (test passes)
4. vision-admission-gate-test.sh TIMEOUT → fixed by Bug A completion
5. full-pipeline/event-sequence.golden → consequence of test failures (shape floor's _sf_floor_verified requires _SF_FAILED_COUNT=0), will auto-resolve when all tests pass
6. parity/event-sequence.golden → same as finding 5

### Changes Applied This Iteration (working tree, uncommitted)

1. `core/pipeline/runner.sh:2827`: `) >/dev/null 2>&1 &` → `) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`
   - Closes the high-numbered fd in the watchdog subshell so orphaned sleep child can't hold the pipe
   - Shellcheck: only pre-existing SC2015 info notes, no new issues

2. `tests/unit/runner-signal-rearm-test.sh:92`: awk pattern `/trap .* TERM$/` → `/trap '.*' TERM$/`
   - Requires single-quoted handler before TERM, skips `trap ':' INT TERM` (the guard line)
   - SC2317 is pre-existing on line 106 (not from this change)

### Verification

- SPEC-2/5/6 acceptance tests (run-limit-precedence-test.sh): all 38 pass ✓
- runner-signal-rearm-test.sh: all 5 pass ✓
- shellcheck runner.sh: only pre-existing SC2015 info notes ✓
- shellcheck runner-signal-rearm-test.sh: only pre-existing SC2317 info note ✓
