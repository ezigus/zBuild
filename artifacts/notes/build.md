# Build notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — acceptance test (READ-ONLY). Has M1/M2 and SPEC-1 assertions. SPEC-1 tests `timed_out`, `out_of_turns`, and `interrupted` outcomes mapping to `ZBUILD_RUN_FLAGGED=yes`. All three currently fail because map.sh only sets flagged=yes on `outcome == fail`.
- `core/pipeline/strategies/map.sh` — line 157 was the bug: `[[ "$outcome" == fail ]] && flagged=yes`. Fixed to `[[ "$outcome" != pass ]] && flagged=yes`.
- Comment at line 132 updated to say "failed or did not finish".
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — Amendment #2368 part 2 updated: description of `ZBUILD_RUN_FLAGGED` now covers unfinished outcomes; `Enforced by` includes SPEC-1 (#1753).
- `core/pipeline/runner.sh` — reviewed for map:* dispatch case. When on_member_error=continue (the template default), _strategy_run_map always returns 0. Runner reads ZBUILD_RUN_FLAGGED via environment (set by _map_write_summary); downstream stages (pr-delivery, pr-open) check it. No code changes needed.

## Changes made
1. `core/pipeline/strategies/map.sh` line 157: `[[ "$outcome" == fail ]]` → `[[ "$outcome" != pass ]]`
2. `core/pipeline/strategies/map.sh` comment: "failed" → "failed or did not finish"
3. `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` #2368 part 2 text + Enforced by updated.

## WIRING: none
`core/pipeline/runner.sh` is in scope for review. After reading the map:* dispatch case (lines 3622–3735): the runner already stops on non-zero rc from _strategy_run_map (lines 3718–3727) and proceeds past the map group only when rc=0. Under on_member_error=continue (the template default), _strategy_run_map returns 0 and exports ZBUILD_RUN_FLAGGED=yes — downstream stages (pr-delivery, merge) already gate on this. Design decision: no changes needed to runner.sh (confirmed by design doc).

## Test results
- All 15 tests pass in `tests/unit/engine-combines-map-test.sh` including SPEC-1 (all 10 non-pass outcomes → ZBUILD_RUN_FLAGGED=yes)
- All 26 tests pass in `tests/integration/runner-release-exit-paths-test.sh` including SPEC-5 (not reproduced on current tree)

## test-author finding response
Finding says SPEC-1 only covers 3 of 10 non-pass outcomes. The tests are read-only, but the test-author stage added the full loop of 10 outcomes. My implementation uses `!= pass` (the universal condition), so ALL non-pass outcomes are correctly handled.

## Status: DONE
