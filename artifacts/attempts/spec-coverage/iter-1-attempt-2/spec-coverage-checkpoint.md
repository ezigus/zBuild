# Spec-coverage checkpoint — issue #2222

## Files read
- design.md: six targeted prose/comment edits to retire `exhausted` from non-historical text; budget-note half confirmed done in #2253. Design explicitly addresses the three spec-correspondence gaps: tests/ exclusion is intentional (meta-references in test file), shell-assignment forms are caught by lint-disposition-words.sh, "dated" requirement is satisfied by #2187 PR number citation.

## Requirement analysis

R-1 (red-first tests for budget note in 4 stages): SPEC-1[done] covers — tests/unit/stage-budget-note-test.sh, per issue comment merged in #2253.

R-2 (changing resolved values changes rendered numbers): SPEC-1[done] covers — same evidence.

R-3 (impact prompt-contract assertions pass): SPEC-2[done] covers — plugins/agent/impact/tests/impact-prompt-contract-test.sh.

R-4 (grep finds `exhausted` only in historical text): SPEC-3[code] covers — text demands "every non-historical occurrence of `exhausted` as a disposition label is removed or annotated with a dated backward-pointer note so the R-4 acceptance grep finds it only in explicitly historical text." TESTFILES: tests/unit/exhausted-disposition-retired-test.sh.

R-5 (npm test and lint green): SPEC-4[done] covers.

## Finding analysis

spec-correspondence finding 1: About the TEST implementation scope, not the SPEC text. SPEC-3 demands that "the R-4 acceptance grep finds it only in explicitly historical text" — this fully covers R-4 at the SPEC level. The test completeness is a build-stage concern, not a spec-coverage gap.

acceptance-gate finding 1: SPEC-3[code] does cover the three edited files (keepers-manifest.yaml, dispatch-rc.sh, review-lens/plugin.sh) — its text says "every non-historical occurrence" and its test file is tests/unit/exhausted-disposition-retired-test.sh. The acceptance-gate concern is about test implementation thoroughness, not about SPEC coverage of R-4.

## Verdict
COVERED — all five requirements are covered by their respective SPECs.
