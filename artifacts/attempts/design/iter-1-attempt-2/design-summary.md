## design — pass

- 7 SPEC(s): DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- DSDIFF-1 (covers RQDIFF-1): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is no_done_sentinel and files_count is 0
- DSDIFF-2 (covers RQDIFF-2): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is router_out_of_turns and files_count is 0
- DSDIFF-3 (covers RQDIFF-3): _build_emit_changed_files_summary emits build.discrepancy.detected and build.diff.empty_after_done_sentinel when terminated_reason is done_sentinel and files_count is 0
- DSEND-1 (covers RQEND-1, RQLOCK-2): the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop lists every concrete reason assigned in route_to_model_loop and every reason _router_rc_classify returns, with no shorthand for the classify subset
- DSLOCK-1 (covers RQLOCK-1): no_done_sentinel and router_out_of_turns are pre-existing reason values; this change reads them without defining new ones
- DSLOCK-2 (covers RQLOCK-3): _router_rc_classify sets verdict to error and reason to router_timeout when called with rc=124
- DSLOCK-3 (covers RQLOCK-4): O4 in route-one-call-per-try-test.sh is not changed
- answered: design finding 1: done — DSLOCK-2's `When`/`Then` previously described reading the file and comparing bytes ("its content is byte-identical to the base-code version"). Replaced with an observable function-call behaviour: when `_router_rc_classify` is called with `rc=124` and `rate_limited=0`, the verdict variable is set to `error` and the reason variable to `router_timeout`. Evidence points to the specific `printf` line in `router-rc-classify.sh` that assigns `router_timeout`. This is something a test can directly observe and assert, without describing what a file contains.
