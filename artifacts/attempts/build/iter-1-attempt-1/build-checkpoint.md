# Build checkpoint — issue #2035 iteration 1

## Files read
- tests/unit/adr-migration-claims-test.sh: acceptance assertions; SPEC-1 checks no "not migrated" text for review-lens/review-report; SPEC-6 checks for _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok anywhere in ADR-028
- docs/adr/ADR-028-shared-llm-agent-framework.md lines 180-199: contained stale "not migrated" paragraph (line 189) and stale sentence in security-lens bullet (line 193)

## Conclusions
- Two tests were failing: [#2035/SPEC-1] and [#2035/SPEC-6]
- Fix: updated ADR-028 to add _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok to per-stage gates block; updated Migration paragraph to include review-lens (#1840) and review-report (#1843); replaced stale "not migrated" paragraph with dated migration note; removed stale "review-lens was not migrated" from security-lens bullet
- All 9 tests now pass

## Status
COMPLETE — all acceptance tests green
