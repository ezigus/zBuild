# Red-team review notes — #1753

## Files read
- core/pipeline/strategies/map.sh (full)
- core/pipeline/runner.sh (lines 3680–3750)
- tests/unit/engine-combines-map-test.sh (full)
- tests/unit/runner-map-parallel-stage-envelope-test.sh (full)
- plugins/agent/pr-delivery/plugin.sh (lines 155–174)
- plugins/tool/merge/plugin.sh (lines 65–80)
- tests/integration/merge-policy-auto-unless-flagged-test.sh (lines 1–80)
- grep results for ZBUILD_RUN_FLAGGED across tests/ and plugins/

## Key observations

### The fix is structurally sound
- map.sh change: `outcome != pass` → `flagged=yes` correctly flags all non-pass outcomes
- runner.sh new guard fires after `_strategy_run_map` returns rc=0 with ZBUILD_RUN_FLAGGED=yes
- runner.sh default `on_member_error=continue` (line 3689) means rc is always 0 for map groups
  unless infra fails or bad_dimension — the new guard IS the primary stop path, by design
- `_map_write_summary` always exported `ZBUILD_RUN_FLAGGED` = yes|no (unconditional at line 179)
  so the guard reads a fresh value, not a stale one

### Finding 1 — event inconsistency for `fail` outcomes (INTRODUCED)
- `parallel.group.complete` event emits verdict from `_ZB_MAP_UNFINISHED` (line 3715)
- `_ZB_MAP_UNFINISHED` tracks only UNFINISHED outcomes (not `fail` — fail is a "finish" per line 158)
- For `on_member_error=continue` + member `fail`: `_ZB_MAP_UNFINISHED` empty → event says `verdict=pass`
- New guard then fires, emits `pipeline.end status=failed`
- Event consumer sees: group=verdict:pass → pipeline:failed, with no intermediate state
- Pre-existing for `on_member_error=collect` (rc-check fired first), INTRODUCED here for `continue`

### Finding 2 — R4 coverage gap (INTRODUCED)
- SPEC-4(c) tests the stop path (ZBUILD_RUN_FLAGGED=yes → _update_stage_status not called)
- NO runtime test verifies that when ZBUILD_RUN_FLAGGED=no (all pass), _update_stage_status IS reached
- A guard inverted to `!= no` or `!= yes` would pass SPEC-4(c) but break R4
- e.g. `[[ "${ZBUILD_RUN_FLAGGED:-}" != no ]]` fires for yes AND for unset —
  SPEC-4 test injects exactly `yes`, so both conditions are identical for the test

### Finding 3 — asymmetric state writes (INTRODUCED)
- New guard (3731-3742): calls both `_set_pipeline_status` AND `_zbuild_state_set_stage_verdict`
- Existing rc-failure path (3718-3727): calls `_set_pipeline_status` but NOT `_zbuild_state_set_stage_verdict`
- `stage_verdicts` in the state file has "failed" entry via new guard, absent via rc path
- Not a security bypass, but different state for downstream readers depending on failure path

### Finding 4 — error message gap (INTRODUCED)
- Error at line 3740: `${_ZB_MAP_UNFINISHED:-a member did not pass}`
- `_ZB_MAP_UNFINISHED` is empty when all members `fail` (fail is a "finish")
- Falls back to "a member did not pass" — doesn't name which member or what outcome
- Pre-existing message behavior changed in severity: old code, `fail` outcomes didn't reach this 
  message (stopped at rc-check or continued); new code, `fail` + `on_member_error=continue` now 
  reaches this message

### Finding 5 — scope expansion beyond review groups (INTRODUCED)
- `ZBUILD_RUN_FLAGGED` is a global variable set by any `_map_write_summary` call
- New guard fires for ALL map groups, not just review groups
- Non-review map group (e.g. build-platforms) with `timed_out` member + `on_member_error=continue`
  now stops the pipeline where it previously would continue
- Issue framing is "review lens" but fix applies universally

### No exploit path found
- Only way to bypass: craft result files with `outcome=pass`. Requires plugin control (trusted code)
- jq failure → outcome=missing → flagged=yes (fail-closed)
- `_map_write_summary` not called for empty/bad_dimension/no_plugin, but those paths either stop
  via rc check or retain prior ZBUILD_RUN_FLAGGED which can't be yes from a prior group that 
  was stopped
- Score: 7

## Verdict
The gate is effectively plugged. The findings are real concerns — particularly the R4 coverage 
gap and the event inconsistency — but none create a bypass path.
