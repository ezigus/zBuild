# Build notes — issue #1769

## Task
1. Update comment in `route_to_model_loop` in `core/router/route.sh` to list every concrete `_ROUTE_LOOP_TERMINATED_REASON` value
2. Extend `_build_emit_changed_files_summary` in `plugins/agent/build/lib/summary.sh` to emit `build.discrepancy.detected` for `no_done_sentinel` and `router_out_of_turns` with zero files changed

## Status: COMPLETE — no code changes needed this iteration

## Changes already committed

### core/router/route.sh (commit 029da230)
Updated the `_ROUTE_LOOP_TERMINATED_REASON` comment in `route_to_model_loop` to list all 10 concrete reason values instead of shorthand:
done_sentinel | no_done_sentinel | router_timeout | router_rate_limited |
router_out_of_turns | router_oom_kill | router_rc_nonzero | router_config_error |
router_budget_exceeded | signal

### plugins/agent/build/lib/summary.sh (commit 029da230)
Extended `_build_emit_changed_files_summary` with an `elif` branch that emits
`build.discrepancy.detected` (with `reason=no_changes_on_incomplete_call`) when
`terminated_reason` is `no_done_sentinel` or `router_out_of_turns` and `files_count` is 0.
The `done_sentinel` path is left unchanged (RQDIFF-3).

## Test-author fixes (commits 5aeaae3b, ff556766)
The test-author stage's latest commit fixed:
- `tests/unit/route-loop-terminated-reasons-test.sh`: added [DSLOCK-2] and [DSLOCK-3] assertions
- `tests/unit/route-one-call-per-try-test.sh`: O4 assertions use plain `[O4]` tags (unchanged from base)
- `tests/unit/router-rc-classify-test.sh`: T2 assertions unmodified

## Verified test results (this iteration — HEAD ff556766)
- plugins/agent/build/tests/build-test.sh: 123/123 pass (DSDIFF-1, DSDIFF-2, DSDIFF-3 all pass)
- tests/unit/route-loop-terminated-reasons-test.sh: 9/9 pass (DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3 all pass)

## Acceptance-gate finding — resolved
The finding "DSLOCK-2/DSLOCK-3: no assertion in the test files carries its tag" was from an
earlier iteration. At HEAD (ff556766) the test file has [DSLOCK-2] at the _router_rc_classify
rc=124 check and [DSLOCK-3] at the git diff check. Both pass. The finding does not reproduce.

## design.md WIRING
`/home/runner/work/_temp/zbuild-state/artifacts/design.md` line 65 declares `WIRING: none`.
The acceptance gate will produce `REACHABILITY EXEMPT none` on re-run.
