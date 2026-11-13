# Build notes — issue #1769

## Task
1. Update comment in `route_to_model_loop` in `core/router/route.sh` to list every concrete `_ROUTE_LOOP_TERMINATED_REASON` value
2. Extend `_build_emit_changed_files_summary` in `plugins/agent/build/lib/summary.sh` to emit `build.discrepancy.detected` for `no_done_sentinel` and `router_out_of_turns` with zero files changed

## Status: COMPLETE

## Changes made

### core/router/route.sh
Updated the `_ROUTE_LOOP_TERMINATED_REASON` comment in `route_to_model_loop` to list all 10 concrete reason values instead of shorthand "a _router_rc_classify reason":
done_sentinel | no_done_sentinel | router_timeout | router_rate_limited | router_out_of_turns | router_oom_kill | router_rc_nonzero | router_config_error | router_budget_exceeded | signal

### plugins/agent/build/lib/summary.sh
Extended `_build_emit_changed_files_summary` with an `elif` branch that emits `build.discrepancy.detected` (with `reason=no_changes_on_incomplete_call`) when `terminated_reason` is `no_done_sentinel` or `router_out_of_turns` and `files_count` is 0. The `done_sentinel` path is left unchanged (RQDIFF-3).

## Tests
All 4 acceptance test files pass:
- plugins/agent/build/tests/build-test.sh — 123/123 (DSDIFF-1, DSDIFF-2, DSDIFF-3 all pass)
- tests/unit/route-loop-terminated-reasons-test.sh — 6/6 (DSEND-1, DSLOCK-1 all pass)
- tests/unit/route-one-call-per-try-test.sh — 14/14
- tests/unit/router-rc-classify-test.sh — 34/34
