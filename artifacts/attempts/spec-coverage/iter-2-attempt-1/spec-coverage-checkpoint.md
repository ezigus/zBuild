# spec-coverage checkpoint

## Files read
- design.md (iter-2): 5 SPECs. SPEC-1[code] covers R-1 R-4; SPEC-2[done] covers R-2 R-3; SPEC-3[done] covers R-2 R-3; SPEC-4[no-code] covers R-1 R-5; SPEC-5[no-code] covers R-2 R-3 R-5. Design note (line 38): prior SPEC-6 declared "subsumed into SPEC-2[done]/SPEC-3[done]".
- requirements.json: R-1 (red-first), R-2 (SPEC-2 extended to review-lens/review-report), R-3 (negative control — bare call turns SPEC-2 red), R-4 (ADR-028 names both stages migrated AND no sentence says otherwise), R-5 (npm test/lint green).

## Conclusions

R-1: Test-ordering / red-first requirement. Per instructions, not in UNCOVERED.

R-2: Covered by SPEC-5[no-code] — extends SPEC-2 loop to check review-lens and review-report for _llm_envelope_parse.

R-3: Covered by SPEC-5[no-code] — reverting migration removes _llm_envelope_parse; SPEC-5 then fails.

R-4: TWO clauses: (1) ADR names both stages as migrated [positive], (2) no sentence says otherwise [negative].
- SPEC-1[code] covers clause 2 only (absence check).
- Prior SPEC-6 covered clause 1 but was removed in iter-2; claimed "subsumed" into SPEC-2[done]/SPEC-3[done].
- SPEC-2[done] and SPEC-3[done] cover the plugin CODE; they say nothing about the ADR document content.
- No SPEC requires ADR-028 to positively record review-lens/review-report as migrated.
- GAP: clause 1 of R-4 is uncovered.

R-5: Green suite / verification requirement. Per instructions, not in UNCOVERED.

## Verdict
VERDICT: uncovered
UNCOVERED: R-4 — positive clause ("ADR-028 names both stages as migrated") has no covering SPEC; SPEC-1 covers only the negative clause; prior SPEC-6 that covered the positive naming was dropped in iter-2 and wrongly declared "subsumed" into code-only SPECs.
