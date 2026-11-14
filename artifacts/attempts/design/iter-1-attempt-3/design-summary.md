## design — pass

- 7 SPEC(s): DSDIFF-1, DSDIFF-2, DSDIFF-3, DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3

- DSDIFF-1 (covers RQDIFF-1): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is no_done_sentinel and files_count is 0
- DSDIFF-2 (covers RQDIFF-2): _build_emit_changed_files_summary emits build.discrepancy.detected when terminated_reason is router_out_of_turns and files_count is 0
- DSDIFF-3 (covers RQDIFF-3): _build_emit_changed_files_summary emits build.discrepancy.detected and build.diff.empty_after_done_sentinel when terminated_reason is done_sentinel and files_count is 0
- DSEND-1 (covers RQEND-1, RQLOCK-2): the _ROUTE_LOOP_TERMINATED_REASON comment in route_to_model_loop lists every concrete reason assigned in route_to_model_loop and every reason _router_rc_classify returns, with no shorthand for the classify subset
- DSLOCK-1 (covers RQLOCK-1): no_done_sentinel and router_out_of_turns are pre-existing reason values; this change reads them without defining new ones
- DSLOCK-2 (covers RQLOCK-3): _router_rc_classify sets verdict to error and reason to router_timeout when called with rc=124
- DSLOCK-3 (covers RQLOCK-4): route-one-call-per-try-test.sh is content-identical before and after this change, confirming O4 was not modified
- answered: lens-scope-design finding 1: done** — The step directing DSDIFF-1/DSDIFF-2 tests had `areas: plugins/agent/build/tests/`, which steered the test-author to `plugins/agent/build/tests/build-test.sh`. The issue scope section explicitly names `tests/unit/build-discrepancy-warn-inside-banner-test.sh`, `tests/integration/build-changed-files-summary-test.sh`, and `tests/unit/build-false-completion-guard-test.sh` as the test files. The step area is corrected to `tests/unit/, tests/integration/` to align with the issue-specified locations.
- answered: lens-scope-design finding 2: wrong** — The issue scope section names test files only for the discrepancy-detection requirements (R1–R3); it is entirely silent about where the R4/DSEND-1 test (the comment-exhaustiveness check) should live. No existing file covers that check. Creating a new file in `tests/unit/` is consistent with the step area `areas: tests/unit/` and the repository's test layout. The scope lens is reading the issue's file list as an exhaustive constraint on a requirement the list never addresses.
