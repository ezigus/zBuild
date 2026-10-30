# Build notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — acceptance test (READ-ONLY). Has M1/M2 and SPEC-1 assertions. SPEC-1 tests non-pass outcomes mapping to `ZBUILD_RUN_FLAGGED=yes`. All pass.
- `core/pipeline/strategies/map.sh` — line 157 was the bug: `[[ "$outcome" == fail ]] && flagged=yes`. Fixed to `[[ "$outcome" != pass ]] && flagged=yes`.
- Comment at line 132 updated to say "failed or did not finish".
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — Amendment #2368 part 2 updated: description of `ZBUILD_RUN_FLAGGED` now covers unfinished outcomes; `Enforced by` includes SPEC-1 (#1753).
- `core/pipeline/runner.sh` — read the map:* dispatch case (lines 3622–3750). Under on_member_error=continue, `_strategy_run_map` returns 0 even with failed/unfinished members. The existing rc!=0 check stopped the run for hard failures. Added new check: after the rc check, if ZBUILD_RUN_FLAGGED=yes (any non-pass member), fail the pipeline and return 1 before pr-delivery runs — satisfying R1 and R2 (run stops before pr_open; no PR is opened; nothing merges).

## Changes made
1. `core/pipeline/strategies/map.sh` line 157: `[[ "$outcome" == fail ]]` → `[[ "$outcome" != pass ]]`
2. `core/pipeline/strategies/map.sh` comment: "failed" → "failed or did not finish"
3. `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` #2368 part 2 text + Enforced by updated.
4. `core/pipeline/runner.sh` map:* case: added ZBUILD_RUN_FLAGGED=yes check after rc check to stop the run with "failed" verdict before pr-delivery, so no PR is opened and nothing merges unless every member passed.

## Test results
- All 15 tests pass in `tests/unit/engine-combines-map-test.sh` including SPEC-1 (all 10 non-pass outcomes → ZBUILD_RUN_FLAGGED=yes)
- All 11 tests pass in `tests/integration/map-members-reported-test.sh` (MR1-MR6 including timed_out and fail cases)

## Findings addressed
- test finding 1: runner.sh IS changed — added ZBUILD_RUN_FLAGGED check that stops the run before pr-delivery
- issue-acceptance R-1: the run now stops in runner.sh before pr-delivery (which contains pr_open) when ZBUILD_RUN_FLAGGED=yes; no PR is opened; nothing merges unless every map member passed

## Status: DONE
