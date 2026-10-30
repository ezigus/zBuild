# Plan notes — issue #1753

## What the issue requires

Bug: `_map_write_summary` (core/pipeline/strategies/map.sh) only flags `ZBUILD_RUN_FLAGGED=yes`
on `fail` outcome. Any other outcome (timed_out, out_of_turns, broken, no result) → `no`, which
lets pr-delivery auto-merge a change nobody reviewed.

Decision (binding):
- Unfinished lens = failed
- Any failed/unfinished element = group fails = run stops (hard stop, no PR, no merge)
- Only all-pass → proceed

Required behaviors R1–R5 all need tests written first.

## Scope (from issue)

Code:
- core/pipeline/strategies/map.sh — _map_write_summary
- core/pipeline/runner.sh — map:* dispatch case
- plugins/agent/pr-delivery/plugin.sh — only if flag semantics change for it
- plugins/tool/merge/plugin.sh — same

ADR:
- docs/adr/ADR-040-composable-gate-lens-taxonomy.md

Named test files:
- tests/unit/engine-combines-map-test.sh (M1, M2)
- tests/integration/map-members-reported-test.sh (MR4–MR6)
- tests/integration/merge-policy-auto-unless-flagged-test.sh
- tests/unit/pr-delivery-v2-result-test.sh
- tests/unit/merge-v2-result-test.sh
- tests/unit/pr-open-v2-result-test.sh
- tests/unit/pr-open-v2-inputs-test.sh
- plugins/tool/pr-open/tests/pr-open-test.sh
+ any files matching grep -rl 'ZBUILD_RUN_FLAGGED' tests/ plugins/

## Step reasoning

1. Grep discovery — issue explicitly requires it; may surface additional test files
2. Write/update failing tests — test-first per repo rules; covers R1–R5 in all named test files
3. Amend ADR-040 — amendment must name enforcing tests (ADR-040 is in baseline so new amendment
   section needs Enforced by inline)
4. Fix map.sh _map_write_summary — core fix: treat anything ≠ pass|fail or no result as flagged
5. Fix runner.sh map:* dispatch — ensure run stops when group fails (may already be handled by
   ZBUILD_RUN_FLAGGED but issue explicitly lists it in scope)
6. Check + update pr-delivery and merge plugins — conditional per issue
7. Full test suite run — confirm R1–R5 pass, no regressions, coverage floor holds

## Open questions

None — issue is well-specified.
