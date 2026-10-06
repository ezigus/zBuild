# Build checkpoint — issue #2222 iter 1

## Files read and conclusions
- `tests/unit/exhausted-disposition-retired-test.sh`: 6 assertions across 6 sites; all pass after changes below.
- `core/pipeline/dispatch-rc.sh:166`: comment said `→ exhausted`; changed to `→ out_of_turns (ADR-054 §6a, #2187)`.
- `plugins/agent/review-lens/plugin.sh:379`: comment said `disposition:exhausted`; changed to `disposition:out_of_turns`.
- `docs/wiki/plugins/review-report.md:137`: said `exhausted when a lens call returned non-zero`; changed to `out_of_turns`.
- `.github/issues/keepers-manifest.yaml:1430`: said `disposition: exhausted` escalates (ADR-054 §6); changed to `out_of_turns` and §6a.
- `docs/adr/ADR-054-stage-contract.md:163`: rc=10 table row kept historical `exhausted` but added `(superseded by §6a / #2187 — now out_of_turns)`.
- `docs/adr/ADR-001-plugin-contract.md:163`: added inline `(exhausted retired #2187; now out_of_turns)` after the word `exhausted`.

## Status
All 6 acceptance assertions pass. Implementation complete.
