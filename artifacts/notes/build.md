# Build notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — acceptance test (READ-ONLY). Has M1/M2 and SPEC-1 assertions. SPEC-1 tests `timed_out`, `out_of_turns`, and `interrupted` outcomes mapping to `ZBUILD_RUN_FLAGGED=yes`. All three currently fail because map.sh only sets flagged=yes on `outcome == fail`.
- `core/pipeline/strategies/map.sh` — line 157 was the bug: `[[ "$outcome" == fail ]] && flagged=yes`. Fixed to `[[ "$outcome" != pass ]] && flagged=yes`.
- Comment at line 132 updated to say "failed or did not finish".
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — Amendment #2368 part 2 updated: description of `ZBUILD_RUN_FLAGGED` now covers unfinished outcomes; `Enforced by` includes SPEC-1 (#1753).

## Changes made
1. `core/pipeline/strategies/map.sh` line 157: `[[ "$outcome" == fail ]]` → `[[ "$outcome" != pass ]]`
2. `core/pipeline/strategies/map.sh` comment: "failed" → "failed or did not finish"
3. `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` #2368 part 2 text + Enforced by updated.

## Test result
- All 8 tests pass in `tests/unit/engine-combines-map-test.sh` including SPEC-1 (timed_out, out_of_turns, interrupted all → ZBUILD_RUN_FLAGGED=yes)

## test-author finding response
Finding says SPEC-1 only covers 3 of 10 non-pass outcomes. The tests are read-only. My implementation uses `!= pass` (the universal condition), not specific outcome names, so ALL non-pass outcomes are correctly handled. The finding is about test breadth — not something I can or need to fix within my scope (tests are read-only).

## Status: DONE
