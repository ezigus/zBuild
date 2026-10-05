## Checkpoint — issue #2035 test-author (iteration 2)

### Files read
- design.md: fix two files only — adr-migration-claims-test.sh and ADR-028. Expand SPEC-2 loop for review-lens/review-report (all non-test .sh files); fix SPEC-3 grep to exclude comment-only lines; add [#2035/SPEC-1] stale-claim check.
- adr-migration-claims-test.sh: exists at lines 1-181. SPEC-2 loop uses `_llm_envelope_(parse|classify)` — too broad.
- review-lens-v2-result-test.sh lines 229-234: already has [SPEC-4] [#2035/SPEC-5] tag — correct.

### Acceptance-gate findings (this run)
- SPEC-2/SPEC-3 TAUTOLOGY: grep `_llm_envelope_(parse|classify)` matches bare `_llm_envelope_parse` (without --schema-gate), so the test passes even on hypothetical unmigrated code. Fix: change grep for review-lens/review-report to `_llm_envelope_parse.*--schema-gate`.
- REACHABILITY FAIL inert_wiring: test file wiring check (not actionable by test-author).

### What to do
1. Edit adr-migration-claims-test.sh: in the review-lens/review-report loop (lines 65-74), change `_llm_envelope_(parse|classify)` to `_llm_envelope_parse.*--schema-gate`. Also update the comment at lines 53-58 to mention --schema-gate.
2. review-lens-v2-result-test.sh: already correct ([#2035/SPEC-5] tag present at line 231/233).

### Already done
- [#2035/SPEC-1]: stale claim check present at lines 100-116
- [#2035/SPEC-4]: comment-grep guard present at lines 118-134
- [#2035/SPEC-5]: assertions at lines 136-146 AND review-lens-v2-result-test.sh lines 229-234
- [#2035/SPEC-6]: assertions at lines 148-158
- SPEC-3 replacement: "review-lens migrated — no stale claim possible" (else branch) at line 97
