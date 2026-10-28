# Test author notes — Issue #1801

## Summary of work
Round 21 — Fix acceptance check for SPEC-4/SPEC-10 e2e tests: add explicit
ZBUILD_ORCHESTRATOR_BACKEND=bash-parallel to both e2e subshells so the test is
independent of the runner's compiled-in default and the backend name reliably
appears in the gate error output.

## Root-cause analysis for this round

### Why the acceptance checker fails for SPEC-4/SPEC-10 e2e

The e2e tests for SPEC-4 and SPEC-10 assert that 'bash-parallel' appears in the
pipeline output. The test relied on ZBUILD_ORCHESTRATOR_BACKEND being unset and
the runner using its "compiled-in default" of bash-parallel. But:

1. The previous test run showed `orchestrator=sequential` in output — the runner's
   default at that point was still 'sequential' (old code).

2. More critically: the new runner.sh gate message needs to name the backend.
   If the gate implementation calls `zbuild_config_get_backend("orchestrator")`
   to get the name, it would get 'bash-parallel' from either the env var or the
   default. But the acceptance checker is not certain which mechanism the
   implementation uses — the test must not rely on defaults.

3. Explicit ZBUILD_ORCHESTRATOR_BACKEND=bash-parallel in the e2e subshell ensures:
   - The env var is available to zbuild_config_get_backend() inside runner.sh
   - The backend name 'bash-parallel' appears in any gate message that reads
     the env var (the standard mechanism)
   - The test is independent of compiled-in defaults

### Why always-run-exit-paths fails (expected)

The failure "[#1801/SPEC-5] persist hook was entered" is an EXPECTED [code] SPEC
failure: on old code, _runner_dispatch_always_run does not dispatch persist.
This test correctly fails on old code and should pass after implementation.
No change needed.

## Changes made in this round

### orch-backend-misconfigured-test.sh

1. Updated comment at the `unset ZBUILD_ORCHESTRATOR_BACKEND` line to reflect
   that each e2e section now sets the backend explicitly in its subshell.

2. SPEC-4 e2e subshell: added `ZBUILD_ORCHESTRATOR_BACKEND=bash-parallel` to
   the env-var block so runner.sh's gate message names bash-parallel.

3. Updated SPEC-10 e2e comment to match (removes the "compiled-in default" claim).

4. SPEC-10 e2e subshell: added `ZBUILD_ORCHESTRATOR_BACKEND=bash-parallel` to
   the env-var block for the same reason.

Result on OLD code: orch_load_backend tries bash-parallel, sequential fallback
fires (if present), 'misconfigured' NOT in output → e2e assertions fail correctly.
Result on NEW code: no fallback, runner.sh gates naming bash-parallel → passes.

## State of all checker/test findings

### always-run-exit-paths: persist hook assertion
Status: EXPECTED failure on old code — [code] SPEC, correct as written.

### orch-backend-misconfigured: SPEC-4/SPEC-10 e2e acceptance check
Status: FIXED — explicit ZBUILD_ORCHESTRATOR_BACKEND=bash-parallel in subshells.

## Full list of test files with assertions

- tests/integration/orch-timeout-applies-test.sh — SPEC-1 ✓
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10 ✓
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3 ✓
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5 ✓
- tests/integration/always-run-exit-paths-test.sh — SPEC-5 ✓ (expected [code] fail on old code)
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
