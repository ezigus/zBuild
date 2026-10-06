# Design checkpoint — #2035 (iteration 4 — final)

## What I read and what it told me

- `adr-migration-claims-test.sh`: SPEC-2 loop at line 56 checks only `plan security-lens monitor`. SPEC-3 grep at line 74 uses `grep -qE 'extract_first_json_object' "$_rl"` — no comment exclusion. Comment at plugin.sh line 403 triggers wrong-branch pass (takes "not migrated" branch, then passes because ADR doesn't say "All four Pattern-1 stages.*review").
- `ADR-028` lines 185-199: stale "not migrated" at line 189 (review-lens and review-report) and line 193 (review-lens). Line 187 lists only `plan`, `security-lens` and `monitor` in Migration. `_review_lens_envelope_schema_ok` and `_rr_lens_envelope_schema_ok` do NOT appear anywhere in the ADR (confirmed by grep returning empty).
- `review-lens/plugin.sh:407`: uses `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok`. Migration complete.
- `review-lens/plugin.sh:403`: has comment mentioning `extract_first_json_object` — causes the SPEC-3 grep to take the wrong branch.
- `review-report/lib/lenses.sh:168`: uses `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok`. Migration complete.
- `review-report/plugin.sh`: no extract_first_json_object or _llm_envelope_parse calls (all parsing is in lib/lenses.sh).
- `config/adr-enforcement-baseline.txt`: ADR-028 is listed (line 33), so the missing `## Enforced by` section doesn't cause lint failure.
- `docs/audits/adr-2026-10-03/batch-3.md`: line 240 documents the contradiction, line 380 confirms SPEC-3 passes on wrong branch.

## spec-coverage findings (iteration 4 answers)

All three findings are addressed by SPEC-6[code] which was added in iteration 3:
- Finding 1: SPEC-6[code] covers R-4 first clause ("ADR-028 names both stages as migrated")
- Finding 2: SPEC-6[code] covers positive presence; SPEC-1[code] covers negative absence
- Finding 3: SPEC-6[code] checks the ADR document for positive migration notation (not plugin code)

## Final SPEC map

- SPEC-1[code]: test assertion that ADR-028 has no "not migrated" text for review-lens/review-report. covers: R-1 R-4
- SPEC-2[done]: review-lens/plugin.sh:407 uses _llm_envelope_parse --schema-gate. covers: R-2 R-3
- SPEC-3[done]: review-report/lib/lenses.sh:168 uses _llm_envelope_parse --schema-gate. covers: R-2 R-3
- SPEC-4[no-code]: SPEC-3 grep uses ^[^#]* to exclude comments. covers: R-1 R-5
- SPEC-5[no-code]: SPEC-2 loop expanded to review-lens and review-report. covers: R-2 R-3 R-5
- SPEC-6[code]: test assertion that ADR-028 names _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok positively. covers: R-4

## WIRING: docs/adr/ADR-028-shared-llm-agent-framework.md
(reverting restores stale text AND removes positive migration note — SPEC-1 and SPEC-6 both fail)

## What is done
Design complete. Writing design.md to /home/runner/work/_temp/zbuild-state/artifacts/design.md.
