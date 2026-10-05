# Build checkpoint — issue #2035 iteration 1

## Files read
- tests/unit/adr-migration-claims-test.sh: acceptance tests already written by test-author stage; [#2035/SPEC-1] was the only failing test (stale "not migrated" claim in ADR)
- docs/adr/ADR-028-shared-llm-agent-framework.md: lines 181-199 contained the stale text
- plugins/agent/review-lens/plugin.sh: confirmed _llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok at line 398
- plugins/agent/review-report/lib/lenses.sh: confirmed _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok at line 162

## Conclusions
- Both plugins were already migrated (#1840/#1843); only the ADR text was stale.
- Made 3 edits to ADR-028: (1) added _review_lens_envelope_schema_ok and _rr_lens_envelope_schema_ok to Per-stage gates list; (2) added review-lens and review-report to the Migration sentence; (3) replaced "not migrated" paragraph with dated migration note; (4) removed false "review-lens was not migrated" claim from security-lens bullet.
- All 9 tests in adr-migration-claims-test.sh now pass. All 54 tests in review-lens-v2-result-test.sh pass.

## Status
COMPLETE — no further work needed.
