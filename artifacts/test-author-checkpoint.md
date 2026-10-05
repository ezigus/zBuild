## Checkpoint — issue #2035 test-author (iteration 4)

### Files read
- design.md: fix adr-migration-claims-test.sh and ADR-028. review-lens/plugin.sh already uses `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` (line 398); review-report/lib/lenses.sh uses `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok` (line 162). ADR-028 still says "not migrated" (lines 189, 193).
- ADR-028: lines 189,193 contain stale "**not** migrated" claims for review-lens/review-report.
- adr-migration-claims-test.sh: original file, 107 lines. No [#2035] tags yet.
- review-lens-v2-result-test.sh lines 228-234: has [SPEC-4] assertion for `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok`. Needs [#2035/SPEC-5] added to labels.

### Plan
1. Update adr-migration-claims-test.sh:
   - Fix old SPEC-3 grep: `extract_first_json_object` → `^[^#]*extract_first_json_object`
   - After old SPEC-2 loop, add [#2035/SPEC-2] (review-lens explicit check)
   - After that, add [#2035/SPEC-3] (review-report/lib/lenses.sh explicit check)
   - After old SPEC-3, add [#2035/SPEC-1] (ADR stale claim - pattern `(review-lens|review-report).*\*\*not\*\*.*migrat`)
   - After that, add [#2035/SPEC-4] (comment-excluding grep guard)
   - Then [#2035/SPEC-5] (review-lens with _review_lens_envelope_schema_ok)
   - Then [#2035/SPEC-6] (review-report with _rr_lens_envelope_schema_ok)
2. Update review-lens-v2-result-test.sh lines 231,233: add [#2035/SPEC-5] to labels

### Status: writing now
