# SRE review notes — issue #1753

## Files read
- core/pipeline/runner.sh (lines 3660–3800)
- core/pipeline/strategies/map.sh (full)
- plugins/agent/pr-delivery/plugin.sh (lines 150–250)
- tests/unit/engine-combines-map-test.sh (full)
- tests/unit/runner-map-parallel-stage-envelope-test.sh (full)

## Change summary
Two code changes:
1. map.sh line 157: `== fail` → `!= pass` so any non-pass outcome sets ZBUILD_RUN_FLAGGED=yes
2. runner.sh lines 3728–3742: new guard after `_strategy_run_map` returns — if ZBUILD_RUN_FLAGGED=yes,
   write pipeline_status=failed, set stage verdict failed, emit pipeline.end, return 1.

## Key flow for on_member_error=continue (the map-group default, line 3689)
_strategy_run_map ALWAYS returns 0 under continue, regardless of member outcomes.
So the _rc != 0 path (lines 3718–3727) is never taken for review lens groups.
The new guard is the ONLY stop mechanism for review lens failures under continue.

## Observability gap: pr.delivery.blocked not emitted for fail outcomes
Before this change:
- `fail` member + continue → _rc=0 → pipeline continues to pr-delivery
- pr-delivery condition at line 161: ZBUILD_RUN_FLAGGED != "no" → falls through
- pr-open invoked, refuses (ADR-001), pr-delivery emits pr.delivery.blocked (line 222)

After this change:
- `fail` member + continue → _rc=0 → new guard fires → pipeline.end emitted, return 1
- pr-delivery NEVER reached → pr.delivery.blocked never emitted
- Any consumer monitoring pr.delivery.blocked for "review found a problem" loses that signal

## Event stream inconsistency for fail outcomes
- parallel.group.complete fires BEFORE the guard (line 3713-3716)
- For fail-only outcomes (no unfinished), _ZB_MAP_UNFINISHED is empty
  → event fires verdict=pass (line 3715: echo incomplete || echo pass)
- Then guard fires → pipeline.end status=failed
- Event stream: "group passed" → "pipeline failed" with no stage.fail for the group

For timed_out/unfinished outcomes: _ZB_MAP_UNFINISHED is set → event fires verdict=incomplete. Less misleading.

## Two failure paths are asymmetric
_rc != 0 path (lines 3718-3727): NO _zbuild_state_set_stage_verdict call
New guard (lines 3728-3742): HAS _zbuild_state_set_stage_verdict "$state_file" "$_mg_id" "failed"
Also: new guard uses `2>/dev/null || true` on eb_emit_event; _rc!=0 path does not.

## Error message vagueness
Guard error at line 3740: "${_ZB_MAP_UNFINISHED:-a member did not pass}"
For fail outcomes: _ZB_MAP_UNFINISHED is empty (only set for timed_out etc.)
→ message says "a member did not pass" without naming the failing lens.

## Rollback safety
Clean: revert map.sh line 157, remove runner.sh lines 3728-3742, revert ADR amendment.
No external state, no schema changes.

## Score: 7
Correct fix, necessary behavior. Main concerns:
- pr.delivery.blocked event loss (medium, introduced)
- parallel.group.complete verdict=pass before hard-stop for fail outcomes (low, worsened)
- vague error message for fail-only outcomes (low, introduced)
- silent eb_emit_event error in new guard (low, introduced)
- asymmetric failure paths (low, introduced)
