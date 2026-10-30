# Design notes — #1753 (revision 3)

## Findings from issue-acceptance stage

### Finding 1: runner.sh stop block untested; SPEC-8 broken

The implementation changed **two** files:
- `map.sh:157`: `[[ "$outcome" == fail ]] && flagged=yes` → `[[ "$outcome" != pass ]] && flagged=yes` ✓
- `runner.sh:3731–3742`: added a stop block after `_strategy_run_map` that returns 1 when `ZBUILD_RUN_FLAGGED=yes`

The stop block is required by R-1 ("the run stops"). The previous design wrongly claimed runner.sh needs no code change. That was wrong — delivery-level blocking (pr-delivery) is not "the run stops"; runner.sh returning 1 before the next stage is.

The stop block broke **SPEC-8** in `runner-map-parallel-stage-envelope-test.sh`:
- Line 44 of that test extracts the map:*) arm via `awk … count>=115`
- The stop block inserts ~14 lines at arm-position ~109 (before `_update_stage_status`)
- `_update_stage_status` is now at arm-position ~121, beyond the 115-line window
- SPEC-8's `assert_contains "$MAP_ARM" '_update_stage_status'` gets an empty MAP_ARM match → FAIL

Confirmed via runner.sh grep:
- map:*) arm starts at line 3622
- Stop block at lines 3731–3742 (arm-position 109–120)
- `_update_stage_status "$state_file" "$_mg_id"` at line 3743 (arm-position 121)
- NEXT case branch `stage:*)` at line 3751 (arm-position 129)
- Arm ends at ;;, arm length ≈ 128 lines

Fix: widen awk window to ≥128 in the test (both fixes SPEC-8 and enables SPEC-4 assertions over the full arm).

### Finding 2: SPEC-4 (new): test for stop block required

No test checks for the ZBUILD_RUN_FLAGGED guard in runner.sh. The acceptance checker confirmed: reverting runner.sh → all tests pass (no test would break). SPEC-4 must be a code-presence assertion in `runner-map-parallel-stage-envelope-test.sh` that greps runner.sh for the guard in the map arm. When runner.sh is reverted, the guard is gone, the test fails.

### Finding 3: SPEC-2 update required

The ADR's `Enforced by` names `engine-combines-map-test.sh` SPEC-1 for flag-setting. The finding says the ADR's amended statement also covers "the run stops" (runner.sh behavior) and the Enforced by must name a test for that too. SPEC-2 needs to:
1. Add ADR text: when `ZBUILD_RUN_FLAGGED=yes`, runner.sh stops the run at the map arm before dispatching further stages
2. Add `runner-map-parallel-stage-envelope-test.sh` SPEC-4 to the Enforced by list

### WIRING: correct after SPEC-4 test added

The acceptance check failed on "inert_wiring: core/pipeline/runner.sh" because no test failed when runner.sh was reverted. After SPEC-4's test is added: reverting runner.sh removes the guard, SPEC-4 fails, at least one test fails → WIRING check passes. WIRING: core/pipeline/runner.sh is correct.

### SPEC-8 supersedes

SPEC-8 (`[SPEC-8] map: dispatch arm writes stage_statuses[id]=complete`) is now wrong: its awk window (115 lines) no longer captures `_update_stage_status`. The behavior it tests is unchanged (success path still writes stage_statuses), but the test implementation gives a false negative. Must be updated (window widened to ≥128).

## Status: writing design-draft.md
