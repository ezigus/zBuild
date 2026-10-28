# Test author notes — Issue #1801

## Summary of work
Round 18 — Final verification. All checker findings from round 2 are confirmed
addressed. Work is complete.

## State of all three checker findings (verified round 18)

### Finding 1: SPEC-4 e2e test (part b) + runner.sh gate static assertion
**Status: RESOLVED** — orch-backend-misconfigured-test.sh contains:
- Lines 216-223: `[#1801/SPEC-4]` static runner.sh gate check
- Lines 235-290: `[#1801/SPEC-4]` e2e rsync install, remove bash-parallel, run pipeline
- Old code: runner.sh has no disposition gate → pipeline doesn't emit "misconfigured" → FAILS ✓
- New code: runner.sh gates early → emits "misconfigured" → PASSES ✓

### Finding 2: SPEC-5 template assertions + pre-existing #1829 SPEC-5
**Status: RESOLVED** — Both test files contain all required assertions:

runner-release-exit-paths-test.sh:
- Lines 454-487: `[#1801/SPEC-5]` timing bound (timeout_s: 5 vs router.timeout_s: 30)
- Lines 469-473: `[#1801/SPEC-5]` static: ZBUILD_RELEASE_TIMEOUT removed
- Lines 482-487: `[#1801/SPEC-5]` static: _TPL_STAGE_ROUTER_TIMEOUT removed
- Lines 519-544: `[#1801/SPEC-5]` simple.yaml release.timeout_s=30, persist.timeout_s=120
- Lines 559-583: `[#1801/SPEC-5]` deployed.yaml release.timeout_s=30, persist.timeout_s=120
- Line 378: pre-existing `[SPEC-5]` #1829 hard-kill cleanup assertion (FAILS on old code — expected)

always-run-exit-paths-test.sh:
- Lines 248-315: `[#1801/SPEC-5]` persist stage dispatch + timing bounds (timeout_s: 4 vs 120)
- Lines 348-370: `[#1801/SPEC-5]` static: always-run-minimal.yaml release.timeout_s=2

### Finding 3: SPEC-10 e2e test (part b)
**Status: RESOLVED** — orch-backend-misconfigured-test.sh contains:
- Lines 299-356: `[#1801/SPEC-10]` e2e rsync install, chmod 000 plugin.sh, run pipeline
- Old code: no runner.sh gate → pipeline doesn't emit "misconfigured" → FAILS ✓
- New code: disposition gate catches it → emits "misconfigured" → PASSES ✓

## Two remaining test failures (both expected on old code)

### Failure 1: `[#1801/SPEC-5] persist hook was entered`
always-run-exit-paths-test.sh line 314.
- **Expected on old code**: always_run persist stage dispatch isn't implemented yet
- **Will pass** after code author implements _runner_dispatch_always_run for persist
- This IS a `[code]` SPEC assertion that must fail on old code

### Failure 2: `[SPEC-5] cleanup dispatched with scope=release for: intake build`
runner-release-exit-paths-test.sh line 378 (pre-existing #1829 assertion).
- **Expected on old code**: runner EXIT trap doesn't dispatch cleanup on hard-kill path
- **Will pass** after code author fixes runner.sh EXIT trap for hard-kill path
- This IS a `[code]` SPEC assertion (pre-existing from #1829) that must fail on old code

## Full list of test files with assertions

- tests/integration/orch-timeout-applies-test.sh — SPEC-1 ✓
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10 ✓
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3 ✓
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5 ✓
- tests/integration/always-run-exit-paths-test.sh — SPEC-5 ✓
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh — SPEC-6 ✓
- tests/unit/lint-adr-enforced-by-test.sh — SPEC-7 ✓
- plugins/tool/orch-mock/tests/orch-mock-test.sh — SPEC-11 ✓
- tests/unit/adr059-no-tmpdir-defaults-test.sh — SPEC-12 ✓
- tests/unit/core-orch-run-id-isolation-test.sh — SPEC-12 ✓
- tests/unit/dispatch-rc-guard-test.sh — SPEC-12 ✓
- tests/unit/stdin-spawn-guard-test.sh — SPEC-12 ✓
- tests/unit/summary-mandatory-test.sh — SPEC-12 ✓
- tests/unit/exit-path-teardown-budget-guard-test.sh — existing checks updated ✓
- tests/unit/plugin-artifact-goldens-test.sh — existing checks updated ✓
