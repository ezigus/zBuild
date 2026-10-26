# Test author notes — Issue #1801

## Summary of work
Round 3 — completed all remaining gaps identified in round 2 notes.

## Final status: COMPLETE

All 10 SPECs have assertions written to disk.

## What was fixed in round 3

### Gap 1: SPEC-2/4/10 missing "misconfigured" check
Added to tests/integration/orch-backend-misconfigured-test.sh after each SPEC's
backend-name check: checks that either the error output contains "misconfigured"
OR `_ZBUILD_ORCH_BACKEND_DISPOSITION == "misconfigured"`. Fails on old code
(which silently succeeds and never reaches a misconfigured path).

### Gap 2: SPEC-5 ZBUILD_RELEASE_TIMEOUT static check
Added to tests/integration/runner-release-exit-paths-test.sh after the timing
assertion: `if ! grep -q 'ZBUILD_RELEASE_TIMEOUT' "$RUNNER"`. Fails on old code
(var present), passes on new code (removed). Covers the second var named in SPEC-5.

## What was already done in previous rounds

### tests/integration/orch-timeout-applies-test.sh [SPEC-1]
- SPEC-1a/b: fanout and sequential spy confirms template_stage_time_limit value (not 300)
- SPEC-1c/d: static grep: map/fanout/sequential have no ZBUILD_ORCH_TIMEOUT reference
- SPEC-1e: runtime: _ORCH_COLLECT_OUTCOME=timed_out on timeout (not "failed")
- SPEC-1f: runtime: strategy propagates timed_out; stderr names stage and limit

### tests/unit/orch-sequential-absent-guard-test.sh [SPEC-3]
- Plugin directory does not exist
- No code/config outside docs/adr/ names "orch-sequential"

### tests/integration/runner-release-exit-paths-test.sh [SPEC-5, SPEC-6]
- [#1801/SPEC-5] runtime timing check + static ZBUILD_RELEASE_TIMEOUT check
- SPEC-6 comment updated to reference timeout_s: (not router.timeout_s)

### tests/unit/orch-kill-uses-pg-kill-guard-test.sh [SPEC-6]
Static: _orch_local_kill_slot and always-run watchdog both call zbuild_pg_kill.
Runtime (TERM-ignoring child) already covered by runner-release-exit-paths-test.sh SPEC-6b.

### tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1 existing check]
Checks _SPEC5_STAGE_TIMEOUT (not ZBUILD_RELEASE_TIMEOUT) — already done.

### tests/unit/plugin-artifact-goldens-test.sh [G5 existing check]
G5 block removed — only G1-G4 remain.

### docs/adr/ADR-011-pluggable-backends.md [SPEC-7]
## Enforced by section added.

### docs/adr/ADR-017-per-stage-router-config.md [SPEC-7]
## Enforced by section added.

### config/adr-enforcement-baseline.txt [SPEC-7]
ADR-011 and ADR-017 absent from the baseline.
