# test-author notes — issue #1769

## Status: COMPLETE (pass 5)

All 7 SPECs have tests written, lint-clean, and verified.
Pass 5 addressed blocking review_lenses findings.

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

Pass 5 changes (addressing review_lenses findings):

1. awk robustness (red-team finding 1, correctness finding 1):
   - Added `; next` after `in_fn=1` so the function-start line is not also
     processed by the `printf` extraction rule.
   - Added `in_fn && /^[a-z_][a-z0-9_]*[[:space:]]*\(\)/ { in_fn=0 }` before
     the `^}` check. This exits the function scope when the next top-level
     function begins, preventing a column-0 `}` inside the function body from
     being the only exit trigger.
   - Original `^}` check kept as belt-and-suspenders.

2. Guard against vacuous pass (red-team finding 2):
   - Added: `if [[ -z "$_required" ]]; then assert_fail "[DSEND-1] GUARD: ..."; fi`
     immediately after `_required` is built (before the membership loops).
   - If grep/awk extraction fails and returns empty, the guard fires assert_fail
     instead of letting the membership loops pass vacuously.
   - In the normal case (_required is non-empty), the if block is not entered
     and no new assertion is emitted — total assertion count unchanged.

DSEND-1 logic (unchanged from pass 3/4):
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

The scope-design finding 1 says these tests should be in different files named in the
issue scope section. The design stage already addressed this finding (answered "done" —
it corrected the step area). The "What you own" section explicitly shows DSDIFF-1/2/3
as already written in build-test.sh. This is "not mine" for test-author.

### NOT MODIFIED: tests/unit/router-rc-classify-test.sh
Unchanged from base.

### NOT MODIFIED: tests/unit/route-one-call-per-try-test.sh
Unchanged from base.

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

### awk function scope tracking
The `_router_rc_classify` function in router-rc-classify.sh has no `}` at column 0
inside its body (all inner blocks use `fi`/`esac`, not `}`). The double-exit-condition
(next function OR bare `^}`) is belt-and-suspenders against future refactoring.

### Non-blocking finding answers (pass 5)
- security finding 2: same awk issue — addressed by the same awk fix above.
- red-team finding 3 (DSLOCK-3 hash): hardcoded `6a07fa8e` is the correct comparison
  point; test passed and the hash is reachable in this worktree.
- correctness finding 2 (DSDIFF-3 no payload check): DSDIFF-3 spec does not include
  a payload "And" clause — no payload check required.
- sre finding 2 (grep scans all of route.sh): conservative — catches more than strictly
  needed, never produces false positives.
- scope-design finding 2 (new test file not in scope): design stage already said "wrong"
  for the same type of issue; tests/unit/ is the correct location.
