# test-author notes — issue #1769

## Status: COMPLETE (pass 3)

All 7 SPECs have tests written, lint-clean, and verified.

## Base code location
`/home/runner/work/_temp/zbuild-state/base-code/`

## Verified behavior

| SPEC | On base code | Expected |
|------|-------------|----------|
| DSDIFF-1 | FAILS (event not emitted for no_done_sentinel) | FAIL |
| DSDIFF-2 | FAILS (event not emitted for router_out_of_turns) | FAIL |
| DSDIFF-3 | PASSES (done_sentinel already emits both events) | PASS |
| DSEND-1 | FAILS (comment uses shorthand, missing 5 reasons) | FAIL |
| DSLOCK-1 | PASSES (pre-existing reasons, no new assignments) | PASS |
| DSLOCK-2 | PASSES (rc=124 → error/router_timeout, existing test) | PASS |
| DSLOCK-3 | PASSES (O4 passes unchanged) | PASS |

## Files modified/created

### MODIFIED: tests/unit/route-loop-terminated-reasons-test.sh
Contains DSEND-1 and DSLOCK-1 tests.

Fixed in pass 3: replaced `|| echo 0` with `|| true` on both grep -c lines
to satisfy lint-grep-c. `grep -c` already prints "0" on no-match; `|| true`
suppresses the non-zero exit inside the subshell without adding a second "0".

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

### MODIFIED: plugins/agent/build/tests/build-test.sh
Added DSDIFF-1, DSDIFF-2, DSDIFF-3 sections at end (before teardown).

Each calls `_build_emit_changed_files_summary` directly with:
- A fresh clean git repo (setup_build_repo) → numstat=empty → files_count=0
- The specific terminated_reason
- Clears events file before call
- Checks build.discrepancy.detected event emitted and payload contains terminated_reason

DSDIFF-3 also checks build.diff.empty_after_done_sentinel.

### NOT MODIFIED: tests/unit/router-rc-classify-test.sh
Reverted in pass 3 to base code. The existing T2 test already asserts rc=124
→ verdict=error, reason=router_timeout (DSLOCK-2). No requirement names this
file or asks for changes to it.

### NOT MODIFIED: tests/unit/route-one-call-per-try-test.sh
Reverted in pass 3 to base code. DSLOCK-3 requires O4 is unchanged; adding
[DSLOCK-3] tags to O4 would change O4, violating the requirement. The existing
O4 test, running unchanged, satisfies DSLOCK-3.

## Technical notes

### grep -c || true
`grep -c` prints the count even when count=0 (exits 1). Inside `$(...)`,
`|| true` lets the subshell exit 0 while the variable still captures "0".
`|| echo 0` was wrong: on no-match it would yield "0\n0".

### DSLOCK-2 and DSLOCK-3 tags
These are [done] SPECs. The existing tests already assert the behavior without
the tags. Adding tags would require modifying the files, which either violates
the requirement (DSLOCK-3: "O4 is not changed") or is disallowed (DSLOCK-2:
no requirement asks for changes to router-rc-classify-test.sh).
