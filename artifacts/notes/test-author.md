# test-author notes — issue #1769

## Status: COMPLETE (pass 4)

All 7 SPECs have tests written, lint-clean, and verified.
DSLOCK-2 and DSLOCK-3 tags now present in test assertions.

## Base code location
`/home/runner/work/_temp/zbuild-state/base-code/`
Base commit SHA: `6a07fa8e`

## Verified behavior

| SPEC | On base code | Expected |
|------|-------------|----------|
| DSDIFF-1 | FAILS (event not emitted for no_done_sentinel) | FAIL |
| DSDIFF-2 | FAILS (event not emitted for router_out_of_turns) | FAIL |
| DSDIFF-3 | PASSES (done_sentinel already emits both events) | PASS |
| DSEND-1 | FAILS (comment uses shorthand, missing 5 reasons) | FAIL |
| DSLOCK-1 | PASSES (pre-existing reasons, no new assignments) | PASS |
| DSLOCK-2 | PASSES (rc=124 → error/router_timeout) | PASS |
| DSLOCK-3 | PASSES (route-one-call-per-try-test.sh unchanged) | PASS |

## Files modified

### MODIFIED: tests/unit/route-loop-terminated-reasons-test.sh
Contains DSEND-1, DSLOCK-1, DSLOCK-2, DSLOCK-3 tests.

Pass 4 added DSLOCK-2 and DSLOCK-3 sections:

DSLOCK-2:
- Sources router-rc-classify.sh (already loaded via summary.sh, source guard OK)
- Uses fresh state dir so no budget marker file exists
- Sets _ROUTE_LAST_BUDGET_EXHAUSTED=0 so budget check doesn't fire
- Calls _router_rc_classify 124 _dslock2_v _dslock2_r 0 (rate_limited=0)
- Asserts verdict=error, reason=router_timeout
- Tagged [DSLOCK-2] in both assertion labels

DSLOCK-3:
- Runs git diff 6a07fa8e..HEAD -- tests/unit/route-one-call-per-try-test.sh
- Asserts output is empty (file is content-identical before and after)
- Tagged [DSLOCK-3] in assertion label
- Does NOT modify route-one-call-per-try-test.sh itself (the git diff test
  lives in this file, not in the file being checked)

DSEND-1 logic (unchanged from pass 3):
1. Extract concrete `_ROUTE_LOOP_TERMINATED_REASON="value"` assignments from route.sh
2. Extract reason values from `_router_rc_classify` in router-rc-classify.sh (awk)
3. Union both sets → required_set
4. Extract tokens from the TERMINATED_REASON comment block in route.sh
5. Assert required ⊆ comment AND comment ⊆ required (exact equality)

Fails on base code because:
- Comment uses shorthand "a _router_rc_classify reason"
- 5 reasons missing: router_budget_exceeded, router_config_error, router_oom_kill, router_out_of_turns, router_rc_nonzero
- 2 extra tokens: reason, router_rc_classify

### MODIFIED: plugins/agent/build/tests/build-test.sh
Contains DSDIFF-1, DSDIFF-2, DSDIFF-3 sections (unchanged from pass 3).

Each calls `_build_emit_changed_files_summary` directly with:
- A fresh clean git repo → numstat=empty → files_count=0
- The specific terminated_reason
- Clears events file before call
- Checks build.discrepancy.detected event emitted and payload contains terminated_reason

DSDIFF-3 also checks build.diff.empty_after_done_sentinel.

### NOT MODIFIED: tests/unit/router-rc-classify-test.sh
Unchanged from base. The DSLOCK-2 assertion is in route-loop-terminated-reasons-test.sh
(a new tagged assertion), not here. No requirement asks to modify this file.

### NOT MODIFIED: tests/unit/route-one-call-per-try-test.sh
Unchanged from base. DSLOCK-3 is a git diff test in route-loop-terminated-reasons-test.sh
that checks this file is unchanged — adding a tag to this file would change it and
break the requirement. The DSLOCK-3 assertion does not live here.

## Technical notes

### grep -c || true
`grep -c` prints the count even when count=0 (exits 1). Inside `$(...)`,
`|| true` lets the subshell exit 0 while the variable still captures "0".

### DSLOCK-2 budget guard
`_router_rc_classify` checks `_ROUTE_LAST_BUDGET_EXHAUSTED` and `_router_budget_observed`
before the rc case. Fresh ZBUILD_STATE_DIR (no marker file) + explicit
`_ROUTE_LAST_BUDGET_EXHAUSTED=0` ensures rc=124 goes to the case block → error/router_timeout.

### DSLOCK-3 base commit
Base commit is `6a07fa8e` (from `git log --oneline -5`).
