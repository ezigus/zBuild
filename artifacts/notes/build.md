# Build notes — issue #1801

## State at start of this call

Previous test stage found 3 failures:
1. runner-job-control-abort-test.sh — "flag-on: monitor mode ON in runner shell" (got: dash=huB)
2. runner-release-exit-paths-test.sh — SPEC-6b (pid still alive 5s after runner returned)
3. stage-timeout-dispatch-test.sh — SPEC-10 (kill -KILL still present)

## What I found at start of previous build iteration

Running tests on tree at start of that iteration:
- stage-timeout-dispatch-test.sh: ALL PASS (SPEC-10 already fixed in prior iteration)
- runner-job-control-abort-test.sh: ALL PASS (flag-on check already fixed in prior iteration)
- runner-release-exit-paths-test.sh: SPEC-5 FAILS with empty marker, SPEC-6b PASSES

## Root cause of SPEC-5 failure (resolved in prior iteration)

The actual bug was BASH TRAP RE-ENTRY in lifecycle.sh. When a second TERM signal
arrives while `sleep 0.1` loops inside zbuild_pg_kill run inside the TERM trap body,
bash delivers the second TERM when `sleep 0.1` exits — re-entering the trap body.

Fix: Move `trap "" TERM` to the VERY BEGINNING of both trap bodies (subshell and 
main-shell). This prevents re-entry: the first thing the trap does is ignore further TERMs.

## Current state (this call)

All three previously failing tests now PASS on current HEAD:
1. stage-timeout-dispatch-test.sh: All 17 PASS ✓
2. runner-job-control-abort-test.sh: All 11 PASS ✓
3. runner-release-exit-paths-test.sh: All 18 PASS ✓

Working tree is clean (git diff HEAD produces no output, git status is clean).
All fixes were committed in the prior build iteration. No further changes needed.
