# test-author notes — issue #1769

## Status: COMPLETE

All 7 SPECs have tests written and verified against base code.

## Base code location
`/home/runner/work/_temp/zbuild-state/base-code/`

## Verified behavior against base code

| SPEC | On base code | Expected |
|------|-------------|----------|
| DSDIFF-1 | FAILS (event not emitted for no_done_sentinel) | FAIL |
| DSDIFF-2 | FAILS (event not emitted for router_out_of_turns) | FAIL |
| DSDIFF-3 | PASSES (done_sentinel already emits both events) | PASS |
| DSEND-1 | FAILS (comment uses shorthand, missing 5 reasons) | FAIL |
| DSLOCK-1 | PASSES (pre-existing reasons, no new assignments) | PASS |
| DSLOCK-2 | PASSES (rc=124 → error/router_timeout) | PASS |
| DSLOCK-3 | PASSES (O4 passes unchanged) | PASS |

## Files modified/created

### MODIFIED: tests/unit/route-loop-terminated-reasons-test.sh
Contains DSEND-1 and DSLOCK-1 tests.

DSEND-1 logic:
1. Extract concrete `_ROUTE_LOOP_TERMINATED_REASON="value"` assignments from route.sh
2. Extract reason values from `_router_rc_classify` in router-rc-classify.sh (awk)
3. Union both sets → required_set (10 unique values)
4. Extract tokens from the TERMINATED_REASON comment block in route.sh
5. Assert required ⊆ comment AND comment ⊆ required (exact equality)

Fails on base code because:
- Comment uses shorthand "a _router_rc_classify reason"
- 5 reasons missing: router_budget_exceeded, router_config_error, router_oom_kill, router_out_of_turns, router_rc_nonzero
- 2 extra tokens: reason, router_rc_classify

DSLOCK-1 structure (fixed in pass 2):
- Sources event-bus.sh, numstat-format.sh, and plugins/agent/build/lib/summary.sh
- Given: static analysis confirms no_done_sentinel exists in route.sh and router_out_of_turns in router-rc-classify.sh
- When: `_build_emit_changed_files_summary` is called with no_done_sentinel and router_out_of_turns on a clean repo
- Then: static analysis confirms build plugin files do not assign _ROUTE_LOOP_TERMINATED_REASON
- All 4 DSLOCK-1 assertions pass on base code and after the change

### MODIFIED: plugins/agent/build/tests/build-test.sh
Added DSDIFF-1, DSDIFF-2, DSDIFF-3 sections at end (before teardown).

Each calls `_build_emit_changed_files_summary` directly with:
- A fresh clean git repo (setup_build_repo) → numstat=empty → files_count=0
- The specific terminated_reason
- Clears events file before call
- Checks build.discrepancy.detected event emitted and payload contains terminated_reason

DSDIFF-3 also checks build.diff.empty_after_done_sentinel.

### MODIFIED: tests/unit/router-rc-classify-test.sh
Added [DSLOCK-2] tags to T2 assertions. Rewrote T2 into Given/When/Then format.

### MODIFIED: tests/unit/route-one-call-per-try-test.sh
Added [DSLOCK-3] tags to O4 assertions. Rewrote O4 into Given/When/Then format.

## Technical notes

### DSLOCK-1 fix
The finding was: When section only did static grep-c counts, never called `_build_emit_changed_files_summary`.

Fix: Added source chain (event-bus.sh, numstat-format.sh, summary.sh) before the DSLOCK-1 section.
When section now creates a clean git repo and calls `_build_emit_changed_files_summary` with both
`no_done_sentinel` and `router_out_of_turns`. Function calls use `|| true` for safety.
Then assertions (static analysis) remain unchanged.

### Event format
Events: `{"type":"...", "data":{"key":"value",...},...}`
Payload check: `jq -r 'select(.type=="T") | .data.terminated_reason'`

### zbuild_engine_tmpdir
Needs ZBUILD_STATE_DIR. Each DSDIFF test section sets its own state dir.

### No SIGPIPE violations
All new code uses here-strings or pipes to non-q grep or sort (safe patterns).
