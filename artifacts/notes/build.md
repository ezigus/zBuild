# Build notes — issue #1769

## Task
1. Update comment in `route_to_model_loop` in `core/router/route.sh` to list every concrete `_ROUTE_LOOP_TERMINATED_REASON` value
2. Extend `_build_emit_changed_files_summary` in `plugins/agent/build/lib/summary.sh` to emit `build.discrepancy.detected` for `no_done_sentinel` and `router_out_of_turns` with zero files changed

## Status: COMPLETE

## Changes committed (across all iterations)

### core/router/route.sh (commit 029da230)
Updated the `_ROUTE_LOOP_TERMINATED_REASON` comment in `route_to_model_loop` to list all 10 concrete reason values instead of shorthand:
done_sentinel | no_done_sentinel | router_timeout | router_rate_limited |
router_out_of_turns | router_oom_kill | router_rc_nonzero | router_config_error |
router_budget_exceeded | signal

### plugins/agent/build/lib/summary.sh (commit 029da230 + this iteration)
Extended `_build_emit_changed_files_summary` with an `elif` branch that emits
`build.discrepancy.detected` (with `reason=no_changes_on_incomplete_call`) when
`terminated_reason` is `no_done_sentinel` or `router_out_of_turns` and `files_count` is 0.
The `done_sentinel` path is left unchanged (RQDIFF-3).

This iteration added `warn "build: loop ended on $terminated_reason with 0 files changed" >&2 || true`
to the new elif branch, matching the pattern of the done_sentinel branch (fixes lens-sre-code finding 1).

## Verified test results (this iteration)
- plugins/agent/build/tests/build-test.sh: 123/123 pass
- tests/unit/route-loop-terminated-reasons-test.sh: 9/9 pass

## review_lenses findings resolution
- lens-sre-code finding 1: FIXED in this iteration — added warn call to the new elif branch
- lens-red-team-code finding 4: FIXED (same change as sre finding 1)
- lens-red-team-code finding 1: does NOT reproduce — test file (lines 50-52) already has dual-exit awk condition (function signature OR bare `^}`)
- lens-red-team-code finding 2: does NOT reproduce — test file (lines 68-71) already has empty _required guard
- lens-red-team-code finding 3: not mine — test file (hardcoded SHA), test-author stage must address
- lens-correctness-code finding 1: does NOT reproduce — same awk dual-exit fix already in test file
- lens-correctness-code finding 2: not mine — test file (DSDIFF-3 payload check), test-author stage must address
- lens-security-code finding 1: not mine — test file (hardcoded short SHA), test-author stage must address
- lens-security-code finding 2: does NOT reproduce — test file already has dual-exit awk
- lens-sre-code finding 2: not mine — test file (grep scans whole route.sh), test-author stage must address
- lens-scope-design finding 1: not mine — design decision already addressed by design stage
- lens-scope-design finding 2: not mine — design decision issue, design stage must address
