## issue-acceptance — pass

- The diff delivers every required change: ADR-028's "not migrated" text is removed and replaced with a dated migration note (SPEC-1 passes its negative control), the SPEC-2 loop is expanded to cover review-lens and review-report with directory-wide non-test `.sh` search (SPEC-2/SPEC-3), SPEC-3's grep gains the `^[^#]*` prefix to exclude comment lines (SPEC-4 negative control passes), and the suite is green; the acceptance-gate's tautology flags on SPEC-2/SPEC-3 are expected — the issue explicitly designed those assertions as confirmatory guards over plugins already migrated in #1840/#1843, not as fail-first behavioral tests, and the issue's own "Red first" requirement names only the comment-exclusion fix (SPEC-3/SPEC-4), which does have a genuine red-first state.

- every requirement the issue states is met by the change
