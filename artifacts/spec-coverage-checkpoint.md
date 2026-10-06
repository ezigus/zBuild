# spec-coverage checkpoint

## Files read
- design.md: 5 SPECs. SPEC-1[code] covers R-1 R-4; SPEC-2[done] covers R-2 R-3; SPEC-3[done] covers R-2 R-3; SPEC-4[no-code] covers R-1 R-5; SPEC-5[no-code] covers R-2 R-3 R-5.
- requirements.json: R-1 (red-first), R-2 (SPEC-2 extended to review-lens/review-report), R-3 (negative control — bare call turns SPEC-2 red), R-4 (ADR-028 both stages named migrated, no sentence says otherwise), R-5 (npm test/lint green).
- tests/unit/adr-migration-claims-test.sh: Confirmed SPEC-2 (line 53-66) checks for `_llm_envelope_parse` presence in `plugin.sh`. SPEC-3 (line 68-84) checks `extract_first_json_object` in review-lens/plugin.sh — takes migrated/not-migrated branch.

## Conclusions

R-1: Test-ordering / red-first requirement. Cannot be judged before code exists. Not in UNCOVERED.

R-2: Covered by SPEC-5[no-code] — SPEC-2 loop extended to check review-lens and review-report for _llm_envelope_parse. Both already have it ([done] per SPEC-2 and SPEC-3).

R-3: SPEC-5 says SPEC-2 checks for _llm_envelope_parse. "Re-introducing a bare call" means replacing _llm_envelope_parse with the old bare call (reverting migration); _llm_envelope_parse gone → SPEC-2 fails. "(not a comment)" clarifies it must be a real call, not a comment. Covered under this reading.

R-4: SPEC-1[code] asserts "ADR-028 does not name review-lens or review-report as not migrated" — this is an ABSENCE check. R-4 has TWO clauses: (1) ADR names both stages as migrated [positive], (2) no sentence says otherwise [negative]. SPEC-1 only covers clause 2. No SPEC demands the ADR positively list review-lens and review-report as migrated in §Migration. Deleting lines 189/193 without adding a positive migration record satisfies SPEC-1 but not R-4. GAP.

R-5: Verification requirement. Cannot be judged before code exists. Not in UNCOVERED.

## Verdict
UNCOVERED: R-4 (first clause — positive naming of both stages as migrated).
