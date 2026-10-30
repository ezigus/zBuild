# Performance lens notes — issue #1753

## Files examined
- core/pipeline/strategies/map.sh (lines 128–183)
- core/pipeline/runner.sh (lines 3700–3750)

## map.sh line 157 change
Old: `[[ "$outcome" == fail ]] && flagged=yes`
New: `[[ "$outcome" != pass ]] && flagged=yes`

Single bash string comparison inside an O(N) loop (N = number of map elements, typically ~6).
No performance difference between equality and inequality test in bash. Trivially O(1) per iteration.

## runner.sh lines 3728–3742 (new stop block)
This is an early-exit guard added after the existing `_rc -ne 0` check.
When `ZBUILD_RUN_FLAGGED=yes`, the block:
- calls `_set_pipeline_status` (one file write)
- calls `_zbuild_state_set_stage_verdict` (one file write)
- calls `eb_emit_event` (O(1))
- calls `_render_pipeline_end` (O(1))
- returns 1

All of these are O(1) operations, identical in kind to those already present in the `_rc -ne 0` path above it. The block short-circuits before `_update_stage_status`, `_zbuild_state_set_stage_verdict` (pass verdict), `eb_emit_event stage.complete`, and `_runner_snapshot_artifacts` — so in the failure path this is a net performance improvement (saves those downstream operations).

## Pre-existing pattern: subprocesses in _map_write_summary loop
Each loop iteration in `_map_write_summary` spawns:
- a subshell for `_registry_output_path_rows` piped to `awk` (line 150)
- a subshell for `_map_member_path` (line 151)
- up to 2 `jq` subshell calls (lines 154–155)

This is O(N * constant_forks) — pre-existing, not introduced by this change. At N=6 (typical review lenses), fork cost is bounded and acceptable.

## String accumulation (pre-existing)
`body+="$line"$'\n'` in bash is O(current_body_length) per iteration due to string copying,
making summary building technically O(N²). Pre-existing, not worsened by this change.
At N=6 with ~100-char lines, total body ~600 chars — not a practical concern.

## Conclusion
No performance regressions introduced. The stop block is an O(1) early exit that saves work
in the failure path. The string-comparison change is performance-neutral.
Score: 10.
