# Design — issue #1769: discrepancy detection for no_done_sentinel and router_out_of_turns

## Decision

`build.discrepancy.detected` is currently emitted only when the router ends
on `done_sentinel` with zero files changed. Two further end-reason values —
`no_done_sentinel` (LLM exited cleanly without the done sentinel) and
`router_out_of_turns` (turn budget exhausted) — also represent a call that
produced no changes and warrant the same signal. The fix extends the guard in
`_build_emit_changed_files_summary` to cover both cases. The `done_sentinel`
path is left exactly as today (RQDIFF-3).

Additionally, the comment in `route_to_model_loop` that lists the possible
`_ROUTE_LOOP_TERMINATED_REASON` values uses the shorthand "a
`_router_rc_classify` reason" rather than enumerating each concrete value. The
comment is updated to list every reason assigned in `route_to_model_loop` and
returned by `_router_rc_classify` (deduplicated). No value is renamed or added
(RQLOCK-1); that is the only change to `core/router/route.sh` (RQLOCK-2);
`scripts/lib/router-rc-classify.sh` is not changed (RQLOCK-3).

```steps
- Update the comment in route_to_model_loop to enumerate every _ROUTE_LOOP_TERMINATED_REASON value concretely | areas: core/router/route.sh
- Extend _build_emit_changed_files_summary to emit build.discrepancy.detected for no_done_sentinel and router_out_of_turns with zero files changed | areas: plugins/agent/build/lib/summary.sh
- Write tests for DSDIFF-1 and DSDIFF-2 (no_done_sentinel and router_out_of_turns each trigger the event when files_count is 0) | areas: plugins/agent/build/tests/
- Write test for DSEND-1 (the route.sh comment lists exactly the full set of end reasons) | areas: tests/unit/
```

```acceptance
DSDIFF-1[code]: _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is no_done_sentinel and files_count is 0 covers: RQDIFF-1
  Given: a build plugin run where route_to_model_loop returns no_done_sentinel
  And: git numstat shows zero files changed
  When: _build_emit_changed_files_summary is called with terminated_reason=no_done_sentinel and files_count=0
  Then: a build.discrepancy.detected event is emitted
  And: the event payload includes terminated_reason=no_done_sentinel

DSDIFF-2[code]: _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is router_out_of_turns and files_count is 0 covers: RQDIFF-2
  Given: a build plugin run where route_to_model_loop returns router_out_of_turns
  And: git numstat shows zero files changed
  When: _build_emit_changed_files_summary is called with terminated_reason=router_out_of_turns and files_count=0
  Then: a build.discrepancy.detected event is emitted
  And: the event payload includes terminated_reason=router_out_of_turns

DSDIFF-3[done]: _build_emit_changed_files_summary emits build.discrepancy.detected and build.diff.empty_after_done_sentinel when terminated_reason is done_sentinel and files_count is 0 covers: RQDIFF-3 evidence: plugins/agent/build/lib/summary.sh | if [[ "$terminated_reason" == "done_sentinel" && "$files_count" -eq 0 \
  When: _build_emit_changed_files_summary is called with terminated_reason=done_sentinel and files_count=0
  Then: build.discrepancy.detected is emitted
  And: build.diff.empty_after_done_sentinel is emitted

DSEND-1[code]: the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop lists every concrete reason assigned in route_to_model_loop and every reason _router_rc_classify returns, with no shorthand for the classify subset covers: RQEND-1, RQLOCK-2
  When: a test extracts every _ROUTE_LOOP_TERMINATED_REASON= assignment from route.sh and every reason= string from _router_rc_classify in router-rc-classify.sh
  Then: the set of concrete reason values equals exactly the set of tokens on the _ROUTE_LOOP_TERMINATED_REASON comment line in route.sh

DSLOCK-1[done]: no_done_sentinel and router_out_of_turns are pre-existing reason values; this change reads them without defining new ones covers: RQLOCK-1 evidence: core/router/route.sh | _ROUTE_LOOP_TERMINATED_REASON="no_done_sentinel"
  When: _build_emit_changed_files_summary checks terminated_reason against no_done_sentinel and router_out_of_turns
  Then: no new _ROUTE_LOOP_TERMINATED_REASON value is assigned anywhere in the changed files

DSLOCK-2[done]: scripts/lib/router-rc-classify.sh contains _router_rc_classify and is not changed covers: RQLOCK-3 evidence: scripts/lib/router-rc-classify.sh | _router_rc_classify()
  When: router-rc-classify.sh is read after this change
  Then: its content is byte-identical to the base-code version

DSLOCK-3[done]: O4 in route-one-call-per-try-test.sh is not changed covers: RQLOCK-4 evidence: tests/unit/route-one-call-per-try-test.sh | # O4 [change] the call takes no call limit: <tier> <prompt_file> <cwd>
  When: the O4 test section runs after this change
  Then: its assertion passes without modification to the test file

WIRING: plugins/agent/build/plugin.sh
```
