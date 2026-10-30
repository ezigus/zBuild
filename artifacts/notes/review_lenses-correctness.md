# Correctness Review Notes — #1753

## Files read
- core/pipeline/runner.sh (lines 3695–3800, 158–240)
- core/pipeline/strategies/map.sh (lines 78–444)
- core/pipeline/state_helpers.sh (lines 1–110)
- tests/unit/engine-combines-map-test.sh
- tests/unit/runner-map-parallel-stage-envelope-test.sh
- docs/adr/ADR-040-composable-gate-lens-taxonomy.md (lines 459–485)

## Key control-flow analysis

### When does the new block fire vs the existing _rc -ne 0 block?

`_strategy_run_map` returns:
- `on_member_error=collect` (default): returns 0 if all orch_collect succeeded, 1 if fail_count > 0
- `on_member_error=continue`: always returns 0

`_map_write_summary` sets ZBUILD_RUN_FLAGGED=yes when any member outcome != pass (NEW: was == fail).

Scenarios:
1. `collect` + member exits non-zero: fail_count++ → _strategy_run_map returns 1 → _rc=1 → EXISTING block fires. New block never reached. ✓
2. `collect` + member exits 0 but writes outcome=fail in result: fail_count=0 → _rc=0 → ZBUILD_RUN_FLAGGED=yes → NEW block fires. ✓ 
3. `continue` + any member failure/outcome != pass: _strategy_run_map returns 0 → _rc=0 → ZBUILD_RUN_FLAGGED=yes → NEW block fires. ✓

## Finding: parallel.group.complete event verdict inconsistency

Lines 3713-3716 (unchanged by this diff):
```
eb_emit_event "parallel.group.complete" "group=$_mg_id" \
    "verdict=$([[ -n "${_ZB_MAP_UNFINISHED:-}" ]] && echo incomplete || echo pass)" \
```

`_ZB_MAP_UNFINISHED` is set only for outcomes that are NOT pass or fail (line 158 map.sh:
  `[[ "$outcome" == pass || "$outcome" == fail ]] || unfinished+=...`).

When members have `outcome=fail` (no unfinished):
- `_ZB_MAP_UNFINISHED=""` → event says `verdict=pass`
- `ZBUILD_RUN_FLAGGED=yes` → new block fires → run stops as "failed"

For `on_member_error=continue` scenario (test fixture uses `continue`):
- BEFORE this change: event `verdict=pass`, `ZBUILD_RUN_FLAGGED=yes` but no stop → run proceeds. Event matched behavior.
- AFTER this change: event `verdict=pass`, new block fires → run stops. Event says "pass" but pipeline fails. Inconsistency introduced.

For `on_member_error=collect` scenario:
- BEFORE this change: _rc=1, existing block fires. Event `verdict=pass` (same inconsistency). Pre-existing.
- This is pre-existing and not introduced by this diff.

Severity: Low — observability only. The state file correctly records "failed" via `_zbuild_state_set_stage_verdict`, and `pipeline.end` event correctly says `status=failed`. Event consumers that rely solely on `parallel.group.complete.verdict` could misread the outcome. But control flow is correct.

## Structural correctness checks passed

- New block only reached when _rc=0 (existing block has early return for _rc!=0). ✓
- `_runner_ended=true` set in new block. ✓
- `unset ZBUILD_CURRENT_STAGE` in new block (consistent with existing failure path). ✓
- `_set_pipeline_status "failed"` in new block. ✓
- `_zbuild_state_set_stage_verdict "failed"` in new block — more state written than existing failure path, intentional per SPEC-4. ✓
- `pipeline.end` event emitted with `2>/dev/null || true`. ✓
- `return 1` stops the run. ✓
- ZBUILD_RUN_FLAGGED always reset by `_map_write_summary` (to "yes" or "no"), so no stale value from previous iteration. ✓

## Test coverage check

- SPEC-1 (flag setting): engine-combines-map-test.sh tests all 10 non-pass outcomes. ✓
- SPEC-4 (stop block): runner-map-parallel-stage-envelope-test.sh 3 assertions:
  (a) ZBUILD_RUN_FLAGGED check precedes _update_stage_status in source — grep-based. ✓
  (b) return 1 inside the if-block — awk extraction + grep. ✓
  (c) runtime: with _rc=0, ZBUILD_RUN_FLAGGED=yes, _update_stage_status not called — eval-based. ✓
- ADR Enforced by: names SPEC-1 and SPEC-4 tests. ✓

## Issue requirements check

- R1: all six lenses non-pass → stop block fires → return 1. ✓
- R2: 5 pass, 1 timed_out → ZBUILD_RUN_FLAGGED=yes → stop block, _ZB_MAP_UNFINISHED names the lens. ✓
- R3: 1 fail → ZBUILD_RUN_FLAGGED=yes → stop block fires. ✓
- R4: all pass → ZBUILD_RUN_FLAGGED=no → new block NOT taken → success path. ✓
- R5: return 1 stops run; no retry. ✓

## No other logic bugs found

No off-by-one, null handling, or other control-flow bugs identified.
