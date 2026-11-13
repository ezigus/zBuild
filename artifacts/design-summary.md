## design — pass

- 7 SPEC(s): DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- DSDIFF-1 (covers RQDIFF-1): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is no_done_sentinel and files_count is 0
- DSDIFF-2 (covers RQDIFF-2): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is router_out_of_turns and files_count is 0
- DSDIFF-3 (covers RQDIFF-3): _build_emit_changed_files_summary emits build.discrepancy.detected and build.diff.empty_after_done_sentinel when terminated_reason is done_sentinel and files_count is 0
- DSEND-1 (covers RQEND-1, RQLOCK-2): the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop lists every concrete reason assigned in route_to_model_loop and every reason _router_rc_classify returns, with no shorthand for the classify subset
- DSLOCK-1 (covers RQLOCK-1): no_done_sentinel and router_out_of_turns are pre-existing reason values; this change reads them without defining new ones
- DSLOCK-2 (covers RQLOCK-3): _router_rc_classify sets verdict to error and reason to router_timeout when called with rc=124
- DSLOCK-3 (covers RQLOCK-4): O4 in route-one-call-per-try-test.sh is not changed
- answered: acceptance-gate finding 1: done — Changed `WIRING: plugins/agent/build/plugin.sh` to `WIRING: none`. The pipeline's reachability check confirmed `plugin.sh` is not on the change path (`REACHABILITY FAIL wiring_not_on_path`). `plugin.sh` already calls `_build_emit_changed_files_summary` before this change and requires no modification for the new guard logic to execute; it is therefore not a file this change touches. `core/router/route.sh` is a comment-only change (`REACHABILITY SKIP no_code`). The only structurally changed file is `plugins/agent/build/lib/summary.sh` (the implementation), which is not the caller. `WIRING: none` is correct.
