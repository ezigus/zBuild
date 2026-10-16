# Test Author Notes — Issue #1801

## Status: COMPLETE (round 2 fix pass)

## Round-2 fixes applied

### 1. stage-timeout-dispatch-test.sh — SPEC-1 roleless leaf awk bug

**Problem**: The awk pattern `/\[\[ -z "\$roles_out" \]\]/` matched the FIRST
occurrence in runner.sh (line 1956, a dry-run display block with no plugin_hook_call).
The assertion would ALWAYS fail, even after the change.

**Fix**: Replaced single-occurrence awk with multi-occurrence scan that looks for
plugin_hook_call within 40 lines of ANY `[[ -z "$roles_out" ]]` occurrence. The
dispatch-path occurrence (line 3760) has plugin_hook_call 21 lines later (line 3781).

Implementation facts:
- runner.sh line 1956: first `[[ -z "$roles_out" ]]` — dry-run block, NO plugin_hook_call
- runner.sh line 3760: second occurrence — DISPATCH path, plugin_hook_call at line 3781

### 2. stage-timeout-no-flat-limit-test.sh — SPEC-7 behavioral test with sleeping orch_collect

**Problem**: The behavioral test (lines 63-136) mocked orch_collect to return 0
immediately. It only checked that --timeout was absent from args. Round-2 checker
requires a test where orch_collect actually runs longer than ZBUILD_ORCH_TIMEOUT.

**Fix**: Added new behavioral section (after line 136) that:
1. Redefines orch_collect to: sleep 2s and return 0 when no --timeout (post-change),
   OR return 1 immediately when --timeout ≤ 1 is passed (simulates old flat ceiling)
2. Re-sources fanout.sh (with guard reset)
3. Overrides _strategy_make_work_unit AFTER sourcing to ensure dispatch_count > 0
4. Runs _strategy_run_fanout with ZBUILD_ORCH_TIMEOUT=1
5. Asserts exit 0 (proves no ceiling fires with 2s dispatch)

FAILS before change: fanout passes --timeout 1 → ceiling fires → rc=1 → assertion fails
PASSES after change: no --timeout → sleeps 2s → returns 0 → rc=0 → assertion passes

## SPEC coverage (final)

SPEC-1:  stage-timeout-dispatch-test.sh ✓ (roleless leaf bug fixed)
SPEC-2:  stage-timeout-process-group-test.sh ✓ + runner-release-exit-paths-test.sh ✓
SPEC-3:  stage-timeout-precedence-test.sh ✓ (isolation test present at lines 153-221)
SPEC-4:  stage-timeout-loader-validation-test.sh ✓
SPEC-5:  stage-timeout-retry-test.sh ✓
SPEC-6:  stage-timeout-always-run-test.sh ✓
SPEC-7:  stage-timeout-no-flat-limit-test.sh ✓ (sleeping behavioral test added)
SPEC-8:  orch-sequential-retired-guard-test.sh ✓
SPEC-9:  orch-backend-misconfigured-test.sh ✓ (unreadable-config names backend at lines 143-150)
SPEC-10: stage-timeout-dispatch-test.sh + stage-timeout-always-run-test.sh ✓
SPEC-11: orch-sequential-retired-guard-test.sh ✓ (specific test names checked at lines 113-196)
SPEC-15: no testfile (grep search, no assertions to write)
SPEC-16: no testfile (npm test/lint pass)
SPEC-17: covered mechanically by SPEC-8 no-orch-sequential grep ✓
SPEC-18: event-schema-emitted-coverage-test.sh ✓ (emitted+registered check at lines 181-198)
SPEC-19: orch-backend-misconfigured-test.sh ✓

## Current test failures (implementation bugs, not test bugs)

1. stage-timeout-dispatch-test.sh SPEC-10: correctly fails because
   lifecycle.sh still has `kill -KILL -- -"$_lc_hook_pid"`.
   Will pass when implementation replaces it with zbuild_pg_kill.

2. runner-release-exit-paths-test.sh SPEC-6b: correctly fails because
   TERM-ignoring grandchild survives.
   Will pass when implementation adds proper group kill.

3. runner-job-control-abort-test.sh: pre-existing failure about `flag-on: monitor mode ON`.
   NOT in my testfile list — cannot touch.

## Files modified in this round

1. tests/unit/stage-timeout-dispatch-test.sh (roleless leaf awk fix)
2. tests/unit/stage-timeout-no-flat-limit-test.sh (behavioral sleeping test)

