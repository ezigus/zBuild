# spec-coverage checkpoint — issue #2035

## Files read
- intake.md: issue text confirming the two tasks: (1) update ADR-028 §Migration to mark review-lens and review-report as migrated, (2) fix adr-migration-claims-test.sh SPEC-2/SPEC-3 grep bugs.
- design.md: 6 SPECs covering the ADR stale-claim assertion (SPEC-1), SPEC-2 loop expansion for review-lens (SPEC-2) and review-report (SPEC-3), comment-excluding grep fix (SPEC-4), and pre-existing code confirmations (SPEC-5/6).

## Conclusions reached
- Issue acceptance checkboxes: 5 items. Two are pipeline-verification (red-first ordering, npm test green) = never gaps by rule. One (negative control) is mutation-testing methodology = never a gap. Two behavioral requirements remain.
- "SPEC-2 covers review-lens and review-report and passes against the code as it is" → covered by design SPEC-2 and SPEC-3 (plus SPEC-5/6 confirming loop expansion).
- "ADR-028 names both stages as migrated; no sentence says otherwise" → covered by design SPEC-1.
- "What is left" section requests to update file header comment and add schema gates to ADR's Per-stage gates list — but these have no corresponding acceptance checkboxes; they are implementation guidance, not verified requirements per the judging rules.
- "search all non-test .sh files" in the issue body is implementation guidance without an acceptance checkbox; its absence from a SPEC is not a gap.

## Verdict
COVERED — all acceptance checkbox requirements are fully covered by the design SPECs.
