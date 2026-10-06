# Impact checkpoint — issue #2035

## What this change does
Fixes ADR-028 and its guard test to reflect that review-lens and review-report
ARE already migrated to _llm_envelope_parse --schema-gate.

Two files actually change:
1. tests/unit/adr-migration-claims-test.sh — fix SPEC-3 grep, expand SPEC-2 loop, add SPEC-1 and SPEC-6 assertions
2. docs/adr/ADR-028-shared-llm-agent-framework.md — update migration record

## Searches performed

### _review_lens_envelope_schema_ok / _rr_lens_envelope_schema_ok
All files referencing these symbols are already in scope:
- docs/audits/adr-2026-10-03/batch-3.md
- plugins/agent/review-lens/plugin.sh
- plugins/agent/review-lens/tests/review-lens-v2-result-test.sh
- plugins/agent/review-report/lib/lenses.sh

### adr-migration-claims-test references
- docs/adr/ADR-028-shared-llm-agent-framework.md — in scope
- docs/audits/adr-2026-10-03/batch-3.md — in scope

### "not migrated" stale claims for review-lens/review-report
Only docs/audits/adr-2026-10-03/batch-3.md — in scope

### Other ADRs referencing review-lens/review-report
None make migration-status claims; they reference stages architecturally.
Not scope gaps.

## Conclusion
No missing files found. All files referencing changed symbols are already in scope.
Verdict: complete
