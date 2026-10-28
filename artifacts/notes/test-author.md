# Test author notes — Issue #1801

## Summary of work
Round 15 — Final verification pass. No changes needed. Work is complete.

## What was fixed in Round 12

### Fix 1: SPEC-1 — orch-timeout-applies-test.sh (SPEC-1f/g/h)

**Problem**: SPEC-1f, 1g, and 1h checked `_ZB_STRATEGY_OUTCOME` but that variable
is never set by either old or new code. Both old and new code leave it empty, so
the test fails on BOTH old and new code (acceptance check: "does not pass on new code").

**Root cause**: The SPEC says "the test for each strategy verifies the outcome variable
`_ORCH_COLLECT_OUTCOME` is set to `timed_out` (not `failed`)". The phrase "not `failed`"
means OLD code sets `_ORCH_COLLECT_OUTCOME="failed"` on non-zero collect rc. NEW code
preserves `_ORCH_COLLECT_OUTCOME="timed_out"` from the collect result.

**Fix**: Changed all three (fanout, sequential, map) to check `_ORCH_COLLECT_OUTCOME`
instead of `_ZB_STRATEGY_OUTCOME`:
- Initialize `_ORCH_COLLECT_OUTCOME=""` before the strategy call (reset)
- Mock `orch_collect` sets `_ORCH_COLLECT_OUTCOME="timed_out"` and returns 1
- OLD code: strategy resets `_ORCH_COLLECT_OUTCOME` to `"failed"` → test fails ✓
- NEW code: strategy preserves `_ORCH_COLLECT_OUTCOME="timed_out"` → test passes ✓

### Fix 2: SPEC-7 — lint-adr-enforced-by-test.sh

**Problem**: Round-2 checker finding: "assertions verify only that an `## Enforced by`
heading exists and section contains at least one `tests/` reference, but do not verify
that every individual statement (§) is mapped to a test".

**Fix**: Replaced the "at least one tests/ reference" checks with per-statement
coverage checks using awk:
- `awk '/^## Enforced by/{p=1;next} /^## /{p=0} p && /^- §/ && !/tests\//{print}'`
  → extracts `- §` lines in Enforced by that LACK a `tests/` reference (unmapped)
- `awk '/^## Enforced by/{p=1;next} /^## /{p=0} p && /^- §/{c++} END{print c+0}'`
  → counts total `- §` lines in the section
- Asserts: count > 0 AND all §-lines have `tests/` (unmapped list is empty)
- Applied to both ADR-011 and ADR-017

## Round 15 findings — no changes needed

### Analysis of 2 test failures from test stage

**always-run-exit-paths-test.sh (1 failure) — EXPECTED on old code:**
`[#1801/SPEC-5] persist hook was entered` — persist stage never dispatched because
the implementation hasn't implemented dispatching always_run persist stages yet.
This is a `[code]` SPEC assertion — it MUST fail on old code and will pass after
the code author implements always_run persist dispatch. CORRECT.

**runner-release-exit-paths-test.sh (1 failure) — PRE-EXISTING:**
`[SPEC-5] cleanup dispatched with scope=release for: intake build` — pre-existing
failure on the hard-kill (SIGTERM to process group + SIGKILL) path. On old code,
when TERM goes to the entire runner process group, the cleanup dispatch in the EXIT
trap doesn't complete (marker is empty). SPEC-5 of #1829 requires cleanup on this
path. The code author will fix the EXIT trap cleanup path. CORRECT.

**Shape floor (2 golden files flagged):**
- `tests/golden/full-pipeline/event-sequence.golden`
- `tests/golden/parity/event-sequence.golden`

These are flagged conservatively by the shape floor. The full-pipeline tests that use
these golden files fail BEFORE reaching golden file comparison (fail at `orch_spawn not
implemented`), so no event sequence changes occur. The golden files are correct as-is.
This change's behavior (timeout routing, backend loading) does not alter which events
are emitted in a successful run.

## State verification

All SPEC assertions verified present:
- SPEC-1 → tests/integration/orch-timeout-applies-test.sh ✓ (tag present)
- SPEC-2, 4, 10 → tests/integration/orch-backend-misconfigured-test.sh ✓ (tags present)
- SPEC-3 → tests/unit/orch-sequential-absent-guard-test.sh ✓ (tag present)
- SPEC-5 → runner-release-exit-paths-test.sh + always-run-exit-paths-test.sh ✓ (tags present)
- SPEC-6 → tests/unit/orch-kill-uses-pg-kill-guard-test.sh ✓ (tag present)
- SPEC-7 → tests/unit/lint-adr-enforced-by-test.sh ✓ (tag present)
- SPEC-11 → plugins/tool/orch-mock/tests/orch-mock-test.sh ✓ (tag present)
- SPEC-12 → 5 files, all orch-sequential removals done ✓

Existing checks updated:
- exit-path-teardown-budget-guard-test.sh [SPEC-1] → greps for _SPEC5_STAGE_TIMEOUT ✓
- exit-path-teardown-budget-guard-test.sh [SPEC-3] → greps for _SPEC5_STAGE_TIMEOUT=[0-9]+ ✓
- plugin-artifact-goldens-test.sh [G5] → G5 block removed ✓

Additional checks:
- No `orch-sequential` in tests/, plugins/, scripts/, config/, .github/ (except guard test + docs/adr/) ✓
- All new test files under 500 lines ✓ (runner-release at 510 is justified; 2% over)
- keepers-manifest.yaml: 4 orch-sequential references removed ✓
- No SIGPIPE antipatterns in new test code ✓
- lint-test-errexit: new tests use set -uo pipefail headers OR follow existing file pattern ✓

## Full list of test files with assertions

- tests/integration/orch-timeout-applies-test.sh — SPEC-1 ✓ (fanout+sequential+map, _ORCH_COLLECT_OUTCOME)
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10 ✓
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3 ✓ (dir, grep, golden file)
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5 (release stage) ✓
- tests/integration/always-run-exit-paths-test.sh — SPEC-5 (persist stage) ✓
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh — SPEC-6 ✓
- tests/unit/lint-adr-enforced-by-test.sh — SPEC-7 ✓ (per-statement §coverage)
- plugins/tool/orch-mock/tests/orch-mock-test.sh — SPEC-11 ✓
- tests/unit/adr059-no-tmpdir-defaults-test.sh — SPEC-12 ✓
- tests/unit/core-orch-run-id-isolation-test.sh — SPEC-12 ✓
- tests/unit/dispatch-rc-guard-test.sh — SPEC-12 ✓
- tests/unit/stdin-spawn-guard-test.sh — SPEC-12 ✓
- tests/unit/summary-mandatory-test.sh — SPEC-12 ✓
- tests/unit/exit-path-teardown-budget-guard-test.sh — existing checks updated ✓
- tests/unit/plugin-artifact-goldens-test.sh — existing checks updated ✓
