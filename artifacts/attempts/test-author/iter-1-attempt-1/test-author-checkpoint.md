## Checkpoint — issue #2035 test-author

### Files read
- design.md: fix two files only — adr-migration-claims-test.sh and ADR-028. Expand SPEC-2 loop for review-lens/review-report (all non-test .sh files); fix SPEC-3 grep to exclude comment-only lines; add [#2035/SPEC-1] stale-claim check.
- adr-migration-claims-test.sh: existing SPEC-0..SPEC-4 (bare tags = issue #2034). SPEC-3 uses grep without comment exclusion — this is the bug.
- ADR-028 line 189: "`review-lens` and `review-report` are **not** migrated" — the stale claim [#2035/SPEC-1] must detect.
- review-lens/plugin.sh line 394 (comment): "schema-gated envelope parser replaces bare extract_first_json_object" — the comment that triggers the wrong SPEC-3 branch.
- review-lens/plugin.sh line 398: `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` — already migrated.
- review-report/lib/lenses.sh line 162: `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok` — already migrated.
- review-lens-v2-result-test.sh lines 228-234: existing [SPEC-4] that checks --schema-gate; need to add [#2035/SPEC-5] tag there.

### Conclusions
- SPEC-2 loop expansion: add review-lens and review-report using find+while loop (no SIGPIPE) over all non-test .sh in plugin dir.
- SPEC-3 fix: change grep to `'^[^#]*extract_first_json_object'` so comment at line 394 is excluded. Result: else branch reached — "review-lens migrated — no stale claim possible".
- [#2035/SPEC-1]: grep for `review-(lens|report).*\*\*not\*\*.*migrated` in ADR; fails now (stale text present), passes after ADR fix.
- [#2035/SPEC-4]: assert `grep -qE '^[^#]*extract_first_json_object' review-lens/plugin.sh` returns FALSE — passes both before and after.
- [#2035/SPEC-5]: grep for `_llm_envelope_parse.*--schema-gate.*_review_lens_envelope_schema_ok` in plugin.sh.
- [#2035/SPEC-6]: grep for `_llm_envelope_parse.*--schema-gate.*_rr_lens_envelope_schema_ok` in lenses.sh.
- review-lens-v2-result-test.sh: add [#2035/SPEC-5] tag alongside existing [SPEC-4] at lines 231/233.

### What to do next
1. Write updated adr-migration-claims-test.sh (all changes).
2. Add [#2035/SPEC-5] tag to review-lens-v2-result-test.sh [SPEC-4] assertions.
