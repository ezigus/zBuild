# Plan checkpoint — issue #2222

## Summary

Part 1 (budget blocks) is DONE in #2253 (merged). Only Part 2 (retire `exhausted`) remains.

## Files read

- intake.md — confirmed Part 1 done, Part 2 still open
- core/pipeline/dispatch-rc.sh:159-186 — line 166 comment says `exhausted`, code at 181 maps `10 → out_of_turns`
- plugins/agent/review-lens/plugin.sh:374-390 — line 379 comment "Write disposition:exhausted"; line 382 code writes `out_of_turns`; "budget_exhausted" is a reason/detail field (not a disposition word)
- plugins/agent/review-report/plugin.sh:160-174 — NO `exhausted` found; already fixed
- docs/wiki/plugins/review-report.md:130-144 — line 137 says `disposition` is `complete`, or `exhausted`
- .github/issues/keepers-manifest.yaml:1424-1432 — line 1430 says `disposition: exhausted` escalates
- docs/adr/ADR-054-stage-contract.md:155-261 — line 163 §4 rc table has `exhausted (§6)`; lines 237-258 are §6a (explicitly historical); issue says add pointer at line 163 to §6a
- docs/adr/ADR-001-plugin-contract.md:158-171 — line 163 is in #1900 retirement note (explicitly historical); issue says add dated pointer to #2187

## Files to change (6 of 7 original targets)

1. core/pipeline/dispatch-rc.sh — fix comment at line 166
2. plugins/agent/review-lens/plugin.sh — fix comment at line 379
3. docs/wiki/plugins/review-report.md — update prose at line 137
4. .github/issues/keepers-manifest.yaml — update prose at line 1430
5. docs/adr/ADR-054-stage-contract.md — add dated pointer at line 163
6. docs/adr/ADR-001-plugin-contract.md — add dated pointer at line 163

## Acceptance verification

After changes: grep finds `exhausted` only in:
- ADR-054 §6 table (lines ~223, explicitly historical per §6a)
- ADR-054 §6a prose (lines ~239, ~258, explicitly describing the migration/retirement)
- ADR-001 #1900 retirement note (explicitly historical)
- review-lens `budget_exhausted` reason field (not a disposition word)
