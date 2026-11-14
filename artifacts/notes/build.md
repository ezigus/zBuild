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

### plugins/agent/build/lib/summary.sh (commit 029da230 + iterations 2 and 3)
Extended `_build_emit_changed_files_summary` with an `elif` branch that emits
`build.discrepancy.detected` (with `reason=no_changes_on_incomplete_call`) when
`terminated_reason` is `no_done_sentinel` or `router_out_of_turns` and `files_count` is 0.
The `done_sentinel` path is left unchanged (RQDIFF-3).

Iteration 2 added a `warn` call to match the done_sentinel branch, but this was removed
in iteration 3 because issue-acceptance finding 1 correctly identified it as exceeding the
acceptance criteria — RQDIFF-1 and RQDIFF-2 require only that build.discrepancy.detected is emitted.

## Verified test results (iteration 3)
- plugins/agent/build/tests/build-test.sh: 123/123 pass
- tests/unit/route-loop-terminated-reasons-test.sh: 9/9 pass

## Finding answers for this iteration

### issue-acceptance finding 1
DONE — removed `warn "build: loop ended on $terminated_reason with 0 files changed" >&2 || true`
from the elif branch in `_build_emit_changed_files_summary`. The warn was added in iteration 2
but no requirement (RQDIFF-1/RQDIFF-2) asks for it.

### lens-sre-code finding 1
WRONG — the warn call is not required by RQDIFF-1 or RQDIFF-2; both requirements state only
that `build.discrepancy.detected` is emitted; adding the warn exceeds scope per
issue-acceptance finding 1; it has been removed.

### lens-red-team-code finding 4
WRONG — the warn was absent because it is out of scope; issue-acceptance finding 1 confirms
that RQDIFF-1/RQDIFF-2 require only the event emission; the warn was removed in iteration 3.

### Test-file findings (not mine)
- lens-red-team-code finding 1: test file — not mine (awk `^}` exit condition in route-loop-terminated-reasons-test.sh)
- lens-red-team-code finding 2: test file — not mine (empty _required guard in route-loop-terminated-reasons-test.sh)
- lens-correctness-code finding 1: test file — not mine (same awk concern as red-team finding 1)
- lens-scope-design finding 1: design stage — not mine (DSDIFF-1/2/3 test area correction)
- build-tests finding 1: not mine (hardcoded SHA in route-loop-terminated-reasons-test.sh)
- build-tests finding 2: not mine (hardcoded SHA in route-loop-terminated-reasons-test.sh)
- build-tests finding 3: not mine (DSDIFF-3 payload assertion in build-test.sh)
- build-tests finding 4: not mine (grep scanning whole route.sh in route-loop-terminated-reasons-test.sh)
