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

## Test-author fixes (commit 5aeaae3b)
The test-author stage's latest commit fixed:
- `tests/unit/route-loop-terminated-reasons-test.sh`: replaced `|| echo 0` with `|| true` on both grep-c lines
- `tests/unit/route-one-call-per-try-test.sh`: reverted O4 to plain `[O4]` tags (no `[DSLOCK-3]` prefix)
- `tests/unit/router-rc-classify-test.sh`: reverted T2 to base code (no `[DSLOCK-2]` prefix)

## Verified test results (this iteration)
- plugins/agent/build/tests/build-test.sh: 123/123 pass (DSDIFF-1, DSDIFF-2, DSDIFF-3 all pass)
- tests/unit/route-loop-terminated-reasons-test.sh: 6/6 pass (DSEND-1, DSLOCK-1 all pass)
- tests/unit/lint-grep-c-test.sh: 21/21 pass
- bash scripts/lib/lint-grep-c.sh: OK (no grep-c || echo occurrences)

## design.md WIRING
`/home/runner/work/_temp/zbuild-state/artifacts/design.md` line 65 declares `WIRING: none`.
The acceptance gate will read this on re-run and produce `REACHABILITY EXEMPT none`.

## Previous findings — all resolved by test-author's latest commit
All findings from the previous test/issue-acceptance run are based on states that
have since been fixed. The working tree has no uncommitted changes (git diff HEAD = empty).
