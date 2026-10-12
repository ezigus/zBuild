# Issue Acceptance Checkpoint — Issue #1801 (current round)

## Files read
- test-results.json: 3 of 29 tests fail (targeted run)

## Exact failures
1. runner-job-control-abort-test.sh T1: set -m in plugin_hook_call leaks monitor mode ON into runner shell
2. runner-release-exit-paths-test.sh SPEC-6b: hook child ignoring TERM still alive 5s after runner returns (R-2)
3. stage-timeout-dispatch-test.sh SPEC-10: kill -KILL -- -"$_lc_hook_pid" found in lifecycle.sh (R-10)

## Verdict
FAIL — R-2 UNMET, R-10 UNMET, R-13 UNMET
