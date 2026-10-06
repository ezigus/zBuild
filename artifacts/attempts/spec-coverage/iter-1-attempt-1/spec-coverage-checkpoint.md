# Spec-coverage checkpoint — issue #2222

## Files read
- design.md: six targeted prose/comment edits to retire `exhausted` from non-historical text; budget-note half confirmed done in #2253.

## Requirement analysis

R-1 (red-first tests for budget note in 4 stages): SPEC-1[done] covers — tests/unit/stage-budget-note-test.sh, per issue comment merged in #2253. The "fails at merge-base" clause is a verification-ordering requirement, not a gap in the SPEC.

R-2 (changing resolved values changes rendered numbers): SPEC-1[done] covers — same evidence.

R-3 (impact prompt-contract assertions pass): SPEC-2[done] covers — plugins/agent/impact/tests/impact-prompt-contract-test.sh.

R-4 (grep finds `exhausted` only in historical text): SPEC-3[no-code] covers — six edits listed; design also accounts for compound tokens like `budget_exhausted` (not a disposition word). TESTFILES: tests/unit/exhausted-disposition-retired-test.sh.

R-5 (npm test and lint green): SPEC-4[done] covers.

## Conclusions
All five requirements are covered. SPEC-3 is [no-code] (still needs implementation) but its text fully demands what R-4 requires.

## Verdict
COVERED
