# Test Author Notes — Issue #1801

## Status: COMPLETE (round 4)

## Round-4 fixes applied

### 1. stage-timeout-process-group-test.sh — SPEC-2 run-hook branch specificity

**Checker finding**: "cannot distinguish a trap placed at function scope from one
confined to the run-hook branch as the requirement specifies"

**Fix**: Replaced whole-body `grep -q 'trap.*TERM'` / `grep -q 'exit 143'` checks
(lines 118-135) with a check that:
1. Extracts only the run-hook branch via awk:
   `if [[ "$hook_name" == "run" ]]; then` → `    else`
2. Verifies `trap.*TERM` and `exit 143` are WITHIN that extracted block

Verification: awk extraction produces 184 lines, trap.*TERM found 8 times,
exit 143 found 4 times. The `else` branch has 0 of both — confirming confinement.
Test now passes 7/7.

### 2. stage-timeout-always-run-test.sh — SPEC-6 visible direct assertions

**Checker finding**: "`_check_stage_timeout` defined without visible calls that
assert the specific required values (release=30, persist=120)"

**Fix**: Added two direct, standalone assertions at the TOP of the `else` block,
before the `_check_stage_timeout` helper definition:
- `_spec6_r` awk check for release=30
- `_spec6_p` awk check for persist=120
These are not inside any helper function, making the requirement unambiguously
visible to both static analysis and code review.

Test now shows release=30 and persist=120 assertions clearly as `✓`.

## SPEC coverage (final)

SPEC-1:  stage-timeout-dispatch-test.sh ✓ (17/17 pass)
SPEC-2:  stage-timeout-process-group-test.sh ✓ (7/7 pass)
SPEC-3:  stage-timeout-precedence-test.sh ✓
SPEC-4:  stage-timeout-loader-validation-test.sh ✓
SPEC-5:  stage-timeout-retry-test.sh ✓
SPEC-6:  stage-timeout-always-run-test.sh ✓ (direct assertions added)
SPEC-7:  stage-timeout-no-flat-limit-test.sh ✓
SPEC-8:  orch-sequential-retired-guard-test.sh ✓ (15/15 pass)
SPEC-9:  orch-backend-misconfigured-test.sh ✓ (7/7 pass)
SPEC-10: stage-timeout-dispatch-test.sh (17/17 pass) +
         stage-timeout-always-run-test.sh (1 fail: impl bug in runner.sh)
SPEC-11: orch-sequential-retired-guard-test.sh ✓
SPEC-15: no testfile (grep search, no assertions to write)
SPEC-16: no testfile (npm test/lint pass)
SPEC-17: covered mechanically by SPEC-8 no-orch-sequential grep ✓
SPEC-18: event-schema-emitted-coverage-test.sh ✓
SPEC-19: orch-backend-misconfigured-test.sh ✓

## Existing check updates

- runner-release-exit-paths-test.sh SPEC-6b: passes 18/18 including SPEC-6b.
  The implementation zbuild_pg_kill is now in place; TERM-ignoring child dies.

## Remaining test failures (implementation bugs, not test bugs)

1. stage-timeout-always-run-test.sh SPEC-10: correctly fails because runner.sh
   line 2486 still has `kill -KILL -- -"$_ar_pid"` in _runner_dispatch_always_run.
   Will pass when implementation replaces it with zbuild_pg_kill.
   Test detection is CORRECT.

2. runner-job-control-abort-test.sh: pre-existing failure about
   `flag-on: monitor mode ON in runner shell`. NOT in my testfile list.
