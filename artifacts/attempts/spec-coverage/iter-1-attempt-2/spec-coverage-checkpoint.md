# spec-coverage checkpoint

## Files read
- design.md (iter-3): 6 SPECs. SPEC-6[code] restored, covers R-4 positive clause by asserting ADR-028 positively names _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok.
- requirements.json (from prior run): R-1 through R-5.

## Conclusions

R-1: verification/test-ordering requirement — exempt from UNCOVERED per instructions. Covered by SPEC-1 and SPEC-4.

R-2: Covered by SPEC-5[no-code] (expands SPEC-2 loop to all non-test .sh files under review-lens/ and review-report/). Also SPEC-2[done] and SPEC-3[done].

R-3: Covered by SPEC-5[no-code] — bare call re-introduced removes _llm_envelope_parse, the loop fails.

R-4: Both clauses covered: positive (ADR names stages migrated) → SPEC-6[code]; negative (no sentence says otherwise) → SPEC-1[code].

R-5: Verification requirement — exempt from UNCOVERED. Also covered by SPEC-4 and SPEC-5.

## Verdict
VERDICT: covered — all requirements covered. Prior gap (R-4 positive clause) fixed by SPEC-6[code] in iter-3.
