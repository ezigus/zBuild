## design — pass

- 7 SPEC(s): DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- DSDIFF-1 (covers RQDIFF-1): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is no_done_sentinel and files_count is 0
- DSDIFF-2 (covers RQDIFF-2): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is router_out_of_turns and files_count is 0
- DSDIFF-3 (covers RQDIFF-3): _build_emit_changed_files_summary emits build.discrepancy.detected and build.diff.empty_after_done_sentinel when terminated_reason is done_sentinel and files_count is 0
- DSEND-1 (covers RQEND-1, RQLOCK-2): the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop lists every concrete reason assigned in route_to_model_loop and every reason _router_rc_classify returns, with no shorthand for the classify subset
- DSLOCK-1 (covers RQLOCK-1): no_done_sentinel and router_out_of_turns are pre-existing reason values; this change reads them without defining new ones
- DSLOCK-2 (covers RQLOCK-3): _router_rc_classify sets verdict to error and reason to router_timeout when called with rc=124
- DSLOCK-3 (covers RQLOCK-4): route-one-call-per-try-test.sh is content-identical before and after this change, confirming O4 was not modified
- answered: design finding 1: done — Changed DSLOCK-3's Then from "at least one assertion labelled [O4] is present in route-one-call-per-try-test.sh" to "git diff is run between the base commit and HEAD restricting to tests/unit/route-one-call-per-try-test.sh; the diff output is empty." An empty diff proves the file is content-identical before and after the change, which is stronger than label-presence: no assertion body can be silently altered while the [O4] label survives. The step description was updated to match.
- answered: acceptance-gate finding 1: done — DSLOCK-3's Then is now a content-identity check (empty git diff output) rather than a label-presence check, so the test-author can write a [DSLOCK-3]-tagged test that runs `git diff base..HEAD -- tests/unit/route-one-call-per-try-test.sh` and asserts empty output. For DSLOCK-2[done], the When/Then describe observable behavior (_router_rc_classify rc=124 → verdict=error, reason=router_timeout); the test-author must add a [DSLOCK-2] tag to the existing rc=124 assertion in router-rc-classify-test.sh — the spec is sufficiently specified for that, and no design change is needed for it.
