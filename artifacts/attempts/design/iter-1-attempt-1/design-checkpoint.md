# Design checkpoint — #2035 (iteration 2)

## What I read and what it told me

- `adr-migration-claims-test.sh` (full file): SPEC-2 loop at line 56 checks only `plan security-lens monitor`. SPEC-3 grep at line 74 uses `grep -qE 'extract_first_json_object' "$_rl"` — no comment exclusion. SPEC-4 (line 92) is a different check (no live code cites a retired ADR).
- `ADR-028` lines 180-199: stale "not migrated" claims at line 189 (review-lens and review-report) and line 193 (review-lens was not migrated). These are the exact lines to fix.
- `review-lens/plugin.sh`: comment at line 403 mentions extract_first_json_object; live call at line 407 uses `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok`. Migration complete.
- `review-report/lib/lenses.sh`: line 168 uses `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok`. Migration complete.
- `review-report/plugin.sh`: no references to extract_first_json_object or migration.
- `review-lens-v2-result-test.sh`: SPEC-4 confirms schema-gate call at plugin.sh.
- `config/adr-enforcement-baseline.txt` line 33: ADR-028 grandfathered.
- `docs/audits/adr-2026-10-03/batch-3.md`: references stale ADR-028 claims in audit findings (historical record, doesn't need updating).

## Critical updates from prior design

- ADR-069 retired `[guard]` tag. Prior design's [guard] → [done] with evidence or [no-code] as appropriate.
- Prior design's [change] → [code].
- ADR-070 requires `covers: R-X` on every SPEC line.
- Comment line in plugin.sh is now 403 (prior design said 394).

## Final SPEC map

- SPEC-1[code]: new test assertion that ADR-028 lacks stale "not migrated" claims; fails on old ADR, passes after. covers: R-1 R-4
- SPEC-2[no-code]: SPEC-2 loop expanded to cover review-lens and review-report. covers: R-2 R-3
- SPEC-3[no-code]: SPEC-3 grep uses ^[^#]* to exclude comments. covers: R-1 R-5
- SPEC-4[done]: review-lens/plugin.sh:407 uses _llm_envelope_parse --schema-gate. evidence: plugins/agent/review-lens/plugin.sh:407. covers: R-2 R-3
- SPEC-5[done]: review-report/lib/lenses.sh:168 uses _llm_envelope_parse --schema-gate. evidence: plugins/agent/review-report/lib/lenses.sh:168. covers: R-2 R-3

## Scope additions beyond prior design

- docs/audits/adr-2026-10-03/batch-3.md: references stale claims

## WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
