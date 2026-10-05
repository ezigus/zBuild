# Design checkpoint — #2035

## Files read and key findings

- `docs/adr/ADR-028-shared-llm-agent-framework.md`: Line 189 says `review-lens` and `review-report` are "not migrated" — STALE. The code was migrated by #1840/#1843. Line 193 also says "review-lens was not migrated".
- `tests/unit/adr-migration-claims-test.sh`: SPEC-3 greps for `extract_first_json_object` in `review-lens/plugin.sh` WITHOUT excluding comment lines. It finds a COMMENT at line 394 of plugin.sh that mentions `extract_first_json_object`, not an actual call. This causes SPEC-3 to take the "not migrated" branch and pass for the wrong reason.
- `plugins/agent/review-lens/plugin.sh:398`: Actually calls `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok`. Migration IS complete.
- `plugins/agent/review-report/lib/lenses.sh:162`: Calls `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok`. Migration IS complete. Parser lives in lib/lenses.sh, NOT plugin.sh.
- `plugins/agent/review-report/plugin.sh`: Sources `lib/lenses.sh` and `scripts/lib/llm-agent.sh`.
- `plugins/agent/review-lens/tests/review-lens-v2-result-test.sh`: Already has SPEC-4 asserting `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` is in plugin.sh — guard.
- `config/adr-enforcement-baseline.txt`: ADR-028 is listed (grandfathered) — no "Enforced by" section required.
- `docs/audits/adr-2026-10-03/batch-3.md`: Records the contradiction. Historical record; no change needed.

## Conclusions reached

1. Two files change: ADR-028 and adr-migration-claims-test.sh.
2. Seed scope is complete.
3. The genuine [change] test for the ADR fix: add a new assertion to the test that FAILS when the ADR contains the stale "not migrated" claim, PASSES after the ADR is updated.
4. SPEC-2 expansion (adding review-lens and review-report to the loop) is additive — passes immediately because code IS migrated. It's [change] because the assertions are new.
5. SPEC-3 grep fix is [guard]: both old and new greps produce a passing assertion, but the new one takes the correct branch.
6. WIRING: tests/unit/adr-migration-claims-test.sh (reads and validates ADR content; reverting it would let stale claims pass undetected).
7. SUPERSEDES: existing SPEC-3 assertion "the ADR does not claim review-lens is migrated" — meaning changes after the fix (the ADR now DOES correctly claim migrated status).

## What I would do next if I had to stop now

Write the design.md with scope block and acceptance block as described above. Core SPECs:
- SPEC-1[change]: new assertion that ADR-028 does not contain "not migrated" claim for review-lens/review-report (fails on current ADR, passes after fix)
- SPEC-2[change]: SPEC-2 loop in test expanded to include review-lens (all non-test .sh files, not just plugin.sh)
- SPEC-3[change]: SPEC-2 loop expanded to include review-report (finds migration in lib/lenses.sh)
- SPEC-4[guard]: SPEC-3 grep excludes comment lines (both branches pass, but right branch taken)
