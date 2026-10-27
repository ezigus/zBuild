# Test author notes — Issue #1801

## Summary of work
Round 10 — COMPLETE. Fixed all 3 issues found by the round-2 checker.

## What was fixed in Round 10

### Fix 1: SPEC-1 — orch-timeout-applies-test.sh
Added SPEC-1g (sequential) and SPEC-1h (map) timed_out propagation tests.

The existing SPEC-1f tested fanout strategy only. The checker said sequential and map only had
the `--timeout` argument spy test, not the `_ZB_STRATEGY_OUTCOME=timed_out` propagation and
stage+limit output assertions.

Added after SPEC-1f (lines 315–381):
- SPEC-1g: `_strategy_run_sequential` with the already-mocked `orch_collect` returning `timed_out`
  - asserts `_ZB_STRATEGY_OUTCOME == "timed_out"`
  - asserts stage name ("testjob") in output
  - asserts timeout limit in output
- SPEC-1h: same pattern for `_strategy_run_map`

Both use `|| _s1g_rc=$?` / `|| _s1h_rc=$?` pattern (no `set -e`).
Both use `grep -q ... <<< "$var"` (no SIGPIPE antipattern).

### Fix 2: SPEC-3 — orch-sequential-absent-guard-test.sh
Added SPEC-3c: direct assertion that `tests/golden/orch-sequential-capabilities.golden` does not exist.

The checker noted: "a file by that name whose content lacks the string 'orch-sequential' would
pass the grep yet violate the requirement." The grep-based SPEC-3b only checked content, not
file existence by name. SPEC-3c does `[[ ! -f "$_golden_file" ]]` to directly check.

### Fix 3: SPEC-7 — lint-adr-enforced-by-test.sh
Added two assertions that verify the `## Enforced by` section in ADR-011 and ADR-017 actually
contains test file references (lines with `tests/`), not just that the heading exists.

Used `awk '/^## Enforced by/{p=1; next} /^## /{p=0} p{print}'` to extract section content,
then `grep -q 'tests/'` to verify it names actual test files.

The checker said: "assertions verify only that an `## Enforced by` heading exists... but do not
verify that the section names actual test files per statement as the requirement specifies."

## Lint/style compliance verified
- No `set -e` violations in any of the 3 modified files (awk lint check confirmed)
- No SIGPIPE antipattern (all grep calls use `<<< "$var"` or direct file args)
- All new code uses `|| rc=$?` pattern
- Files stay under 500 lines (385, 74, 151 lines respectively)

## Full list of test files with assertions

- tests/integration/orch-timeout-applies-test.sh — SPEC-1 ✓ (fanout+sequential+map propagation)
- tests/integration/orch-backend-misconfigured-test.sh — SPEC-2, SPEC-4, SPEC-10 ✓
- tests/unit/orch-sequential-absent-guard-test.sh — SPEC-3 ✓ (dir, grep, golden file)
- tests/integration/runner-release-exit-paths-test.sh — SPEC-5 (release stage) ✓
- tests/integration/always-run-exit-paths-test.sh — SPEC-5 (persist stage) ✓
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh — SPEC-6 ✓
- tests/unit/lint-adr-enforced-by-test.sh — SPEC-7 ✓ (section exists + names test files)
- plugins/tool/orch-mock/tests/orch-mock-test.sh — SPEC-11 ✓
- tests/unit/adr059-no-tmpdir-defaults-test.sh — SPEC-12 ✓
- tests/unit/core-orch-run-id-isolation-test.sh — SPEC-12 ✓
- tests/unit/dispatch-rc-guard-test.sh — SPEC-12 ✓
- tests/unit/stdin-spawn-guard-test.sh — SPEC-12 ✓
- tests/unit/summary-mandatory-test.sh — SPEC-12 ✓
- tests/unit/exit-path-teardown-budget-guard-test.sh — existing checks updated ✓
- tests/unit/plugin-artifact-goldens-test.sh — existing checks updated ✓
