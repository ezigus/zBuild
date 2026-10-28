# Test author notes — Issue #1801

## Summary of work
Round 12 — Fixed 2 remaining issues found by the test stage.

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
- Updated comments and assert messages accordingly

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
- Reads file directly — no pipeline, no SIGPIPE risk

### keepers-manifest.yaml (unchanged from round 11)

The working-tree fix that removes 4 `orch-sequential` references is already on disk
(git diff shows it modified). No new changes needed.

## State verification

- `grep -rn "orch-sequential" core/ plugins/ scripts/ config/ tests/ .github/`
  (excluding docs/adr/ and the guard test itself) → 0 results ✓
- No `set -e` violations in files with `set -uo pipefail` headers ✓
- No SIGPIPE antipattern in new code ✓
- All new assertions use `|| rc=$?` or `|| true` pattern ✓
- orch-timeout-applies-test.sh: 388 lines (under 500) ✓
- lint-adr-enforced-by-test.sh: 154 lines (under 500) ✓

## Why the other test stage failures are pre-existing

The test stage shows many other failures (artifact-contract, core-pipeline-runner,
etc.) that are NOT in my scope. These are either:
1. Integration tests that fail because the full implementation isn't present yet
2. Pre-existing failures in the repo unrelated to my test assertions

The tests I authored (SPEC-1 through SPEC-12) are expected to FAIL on old code
and PASS on new code. The failing tests from the test stage for things like
"happy path exits 0" are integration tests that require the full implementation.

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
