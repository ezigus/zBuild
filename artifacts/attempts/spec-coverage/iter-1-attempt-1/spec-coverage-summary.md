## spec-coverage — uncovered

- SPEC-1 only checks that ADR-028 has no stale "not migrated" claim, but no SPEC demands the ADR positively list review-lens and review-report as migrated — deleting lines 189/193 without adding a migration record satisfies SPEC-1 while leaving the first clause of R-4 unverified.

- NOT COVERED: R-4: "ADR-028 names both stages as migrated
- NOT COVERED: no sentence in it says otherwise" — SPEC-1[code] covers only the second clause (no sentence says "not migrated")
- NOT COVERED: no SPEC demands a sentence affirmatively placing review-lens and review-report in §Migration alongside plan, security-lens, and monitor
- NOT COVERED: removing lines 189 and 193 without adding a positive migration note (dated, citing #1840/#1843) satisfies SPEC-1 but does not satisfy the requirement that the ADR names both stages as migrated
