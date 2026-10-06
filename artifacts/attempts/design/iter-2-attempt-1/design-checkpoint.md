# Design checkpoint — #2035 (iteration 3)

## What I read and what it told me

- `adr-migration-claims-test.sh`: SPEC-2 loop at line 56 checks only `plan security-lens monitor`. SPEC-3 grep at line 74 uses `grep -qE 'extract_first_json_object' "$_rl"` — no comment exclusion. Comment at plugin.sh line 403 triggers wrong-branch pass.
- `ADR-028` lines 185-199: stale "not migrated" at line 189 (review-lens and review-report) and line 193 (review-lens). Line 187 lists only `plan`, `security-lens` and `monitor` in Migration. `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` do NOT appear anywhere in the ADR.
- `review-lens/plugin.sh:407`: uses `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok`. Migration complete.
- `review-report/lib/lenses.sh:168`: uses `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok`. Migration complete.

## spec-coverage findings addressed in iteration 3

spec-coverage found R-4 not fully covered: SPEC-1 checks absence of "not migrated" text but no SPEC checks that ADR-028 POSITIVELY names both stages as migrated.

Fix: add SPEC-6[code] — test assertion that ADR-028 names `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` in its migration record. Fails on current ADR (both absent), passes after ADR update. covers: R-4.

## Final SPEC map (iteration 3)

- SPEC-1[code]: test assertion that ADR-028 has no "not migrated" text for review-lens/review-report. covers: R-1 R-4
- SPEC-2[done]: review-lens/plugin.sh:407 uses _llm_envelope_parse --schema-gate. covers: R-2 R-3
- SPEC-3[done]: review-report/lib/lenses.sh:168 uses _llm_envelope_parse --schema-gate. covers: R-2 R-3
- SPEC-4[no-code]: SPEC-3 grep uses ^[^#]* to exclude comments. covers: R-1 R-5
- SPEC-5[no-code]: SPEC-2 loop expanded to review-lens and review-report. covers: R-2 R-3 R-5
- SPEC-6[code]: test assertion that ADR-028 names _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok positively. covers: R-4

## WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
(reverting restores stale text AND removes positive migration note — SPEC-1 and SPEC-6 both fail)
