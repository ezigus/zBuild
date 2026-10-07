# Issue Acceptance Checkpoint — #2222

## Files read
- plugins/agent/review-report/plugin.sh — no `exhausted` found; site already clean before this diff
- docs/adr/ADR-054-stage-contract.md lines 210-268 — §6 original table (line 223) retains `exhausted` as historical; §6a explicitly says "The rule above... is replaced" making §6 explicitly historical
- tests/unit/stage-budget-note-test.sh — covers N1-N4+N6: N1-N3 prove shared function renders from resolver values; N2 (line 44, max_turns=0→no turn note) proves values not hard-copied; N4 greps every model-calling plugin for budget note presence; N6 drives spec-correspondence end-to-end with 300s value

## R-4 grep analysis
Ran: grep -rnE 'exhausted' core plugins scripts docs/wiki .github/issues docs/adr/ADR-001* docs/adr/ADR-054*
Remaining hits are:
- `budget_exhausted` as event/function names (not a disposition label)
- English word "exhausted" in descriptions of turn budget use
- `core/pipeline/disposition.sh:28` — explicitly historical comment "(exhausted was retired by #2187)"
- `docs/adr/ADR-054-stage-contract.md:223` — in original §6 table, superseded by §6a
- `docs/adr/ADR-054-stage-contract.md:239,258` — in §6a as historical reference
- `docs/adr/ADR-001-plugin-contract.md:163` — annotated with "(exhausted retired #2187; now out_of_turns)"
None are prescriptive disposition labels.

## Conclusions
- R-1: met (N4+N1-N3+N2 prove all four stages use budget note rendered from resolver values)
- R-2: met (N2: changing max_turns to 0 suppresses turn note — proves not hard-copied)
- R-3: met (test suite passes)
- R-4: met (remaining hits are English, event names, or explicitly historical ADR text)
- R-5: met (TEST VERDICT: pass)

VERDICT: pass
