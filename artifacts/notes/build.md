# Build notes — issue #1753

## What I read
- `tests/unit/engine-combines-map-test.sh` — acceptance test. Has M1/M2 and SPEC-1 assertions. All 15 pass.
- `tests/unit/runner-map-parallel-stage-envelope-test.sh` — updated by test-author: awk window widened to 128; SPEC-4 for #1753 added (lines 95-155, three assertions). All 19 pass.
- `core/pipeline/strategies/map.sh` — line 157: `[[ "$outcome" != pass ]]` (prior build). All non-pass outcomes set ZBUILD_RUN_FLAGGED=yes.
- `core/pipeline/runner.sh` — lines 3728-3742: ZBUILD_RUN_FLAGGED stop block (prior build). Returns 1 before _update_stage_status at line 3743.
- `docs/adr/ADR-040-composable-gate-lens-taxonomy.md` — §2368 part 2 body had non-pass wording but was missing: (1) run-stops sentence, (2) runner-map-parallel-stage-envelope-test.sh SPEC-4 in Enforced by. FIXED this iteration.

## Changes made this iteration
1. `docs/adr/ADR-040-composable-gate-lens-taxonomy.md`: Added run-stops bullet to §2368 part 2 body; added `tests/unit/runner-map-parallel-stage-envelope-test.sh` SPEC-4 (#1753) to Enforced by.

## Findings addressed
- test finding 1: SPEC-8 passes — test-author widened awk window to 128; _update_stage_status at count 122 is within window.
- test finding 2: nothing to do — tests using full-pipeline golden pass; golden covers build-stage events unrelated to map arm.
- test finding 3: nothing to do — tests using parity golden pass; unrelated to map arm changes.
- test finding 4: SPEC-4 assertions in runner-map-parallel-stage-envelope-test.sh grep MAP_ARM for `ZBUILD_RUN_FLAGGED:-` before `_update_stage_status`. Reverting runner.sh removes the guard → spec4_flagged_cnt=0 ≠ 1 → SPEC-4 fails. Wiring confirmed.
- issue-acceptance finding 1: runner.sh stop block now tested by SPEC-4 assertions.
- issue-acceptance finding 2: ADR Enforced by now names SPEC-4; ADR body now states run-stops behavior.

## Status: DONE
