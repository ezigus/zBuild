## issue-acceptance — pass

- The diff meets every issue requirement — ADR-028's stale "not migrated" prose is replaced with a dated migration note, the SPEC-3 grep now excludes comment lines (NEGCTL PASS SPEC-4 confirms the fix), the SPEC-2 loop is expanded to cover review-lens and review-report across all non-test `.sh` files, and the acceptance-gate's "tautology" label on SPEC-2/SPEC-3 reflects that the underlying plugins were already correctly migrated (#1840/#1843), not a gap in the diff; the issue's stated negative control ("re-introducing a bare call turns SPEC-2 red") is a forward-guard property of the new loop and is satisfied — the old loop had no coverage of these plugins at all.

- every requirement the issue states is met by the change
