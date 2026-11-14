# test-author notes — issue #1769

## Status: COMPLETE (pass 6)

All 7 SPECs have tests written, lint-clean, verified, and all findings answered.
Pass 6: answering all previously-open findings; no code changes needed.

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

Pass 5 changes (all still in place in pass 6, no further changes needed):

1. awk robustness (addresses red-team finding 1, correctness finding 1, security finding 2):
   - Line 50: `; next` after `in_fn=1` prevents function-start line from being processed
   - Line 51: `in_fn && /^[a-z_][a-z0-9_]*[[:space:]]*\(\)/ { in_fn=0 }` exits on next function
   - Line 52: `in_fn && /^}[[:space:]]*$/ { in_fn=0 }` exits on bare column-0 `}` (belt-and-suspenders)

2. Guard against vacuous pass (addresses red-team finding 2):
   - Lines 68-71: `if [[ -z "$_required" ]]; then assert_fail "[DSEND-1] GUARD: ..."; fi`
   - If grep/awk extraction fails and returns empty, the guard fires assert_fail
     instead of letting the membership loops pass vacuously.

DSEND-1 logic:
1. Extract concrete `_ROUTE_LOOP_TERMINATED_REASON="value"` assignments from route.sh (grep)
2. Extract reason values from `_router_rc_classify` in router-rc-classify.sh (awk with dual-exit)
3. Union both sets → required_set, with guard against empty extraction
4. Extract tokens from the TERMINATED_REASON comment block in route.sh
5. Assert required ⊆ comment AND comment ⊆ required (exact equality)

Fails on base code because:
- Comment uses shorthand "a _router_rc_classify reason"
- 5 reasons missing: router_budget_exceeded, router_config_error, router_oom_kill, router_out_of_turns, router_rc_nonzero
- 2 extra tokens: reason, router_rc_classify (from shorthand text)

### MODIFIED: plugins/agent/build/tests/build-test.sh
Contains DSDIFF-1, DSDIFF-2, DSDIFF-3 sections (unchanged from pass 3).

Each calls `_build_emit_changed_files_summary` directly with:
- A fresh clean git repo → numstat=empty → files_count=0
- The specific terminated_reason
- Clears events file before call
- Checks build.discrepancy.detected event emitted and payload contains terminated_reason

DSDIFF-3 also checks build.diff.empty_after_done_sentinel.

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
Base commit is `6a07fa8e`. The hardcoded SHA is intentional: DSLOCK-3 specifically
checks this worktree's invariant. If the SHA is unreachable (e.g. rebased),
the test fails with a non-empty diff — which IS the correct behavior (the test
cannot perform its assertion and should fail, not silently pass).

### awk function scope tracking
The dual-exit-condition in lines 51-52 prevents premature truncation:
- Line 51: exits `in_fn` when the next top-level function signature appears
- Line 52: exits `in_fn` on a bare column-0 `}` (belt-and-suspenders)
`_router_rc_classify` currently has no column-0 `}` inside its body.

## Finding answers (pass 6)

### build-tests findings (from issue-acceptance "not answered")
- build-tests finding 1 (lens-security-code finding 1, hardcoded SHA): wrong — the SHA
  `6a07fa8e` is the base commit for this worktree and is reachable; `2>&1 || true`
  captures git fatal errors and makes `_dslock3_diff` non-empty, failing the assertion
  with a clear message; this is the correct failure mode for a worktree-specific invariant
  check; a rebase scenario where the SHA is unreachable IS a signal that the test cannot
  perform its assertion and should report failure.
- build-tests finding 2 (lens-red-team-code finding 3, hardcoded SHA): wrong — same reasoning.
- build-tests finding 3 (lens-correctness-code finding 2, DSDIFF-3 no payload): wrong —
  DSDIFF-3's requirement has no "And" payload clause; the spec says only "build.discrepancy.detected
  is emitted" and "build.diff.empty_after_done_sentinel is emitted"; DSDIFF-1 and DSDIFF-2
  each have explicit payload clauses; DSDIFF-3 does not; adding a payload check would
  assert more than the requirement demands.
- build-tests finding 4 (lens-sre-code finding 2, grep scans all route.sh): wrong — scanning
  all of route.sh is conservative; `signal` from `_route_signal_handler` is a value
  `route_to_model_loop` reaches via its signal handler; the extraction is correct and
  cannot produce false positives.

### review_lenses findings
- lens-security-code finding 2: wrong — lines 51-52 already implement dual-exit; fix applied in pass 5.
- lens-red-team-code finding 1: wrong — dual-exit awk already in test (line 51); fix applied in pass 5.
- lens-red-team-code finding 2: wrong — guard already in test (lines 68-71); fix applied in pass 5.
- lens-red-team-code finding 3: wrong — hardcoded SHA is correct for worktree-specific invariant.
- lens-correctness-code finding 1: wrong — dual-exit awk already in test; fix applied in pass 5.
- lens-correctness-code finding 2: wrong — DSDIFF-3 requirement has no payload "And" clause.
- lens-sre-code finding 2: wrong — conservative scan is correct; `signal` is reachable via handler.
- lens-scope-design finding 1: not mine — design stage already answered this "done"; the "What you
  own" section explicitly lists build-test.sh as the already-written location for DSDIFF-1/2/3.
- lens-scope-design finding 2: wrong — tests/unit/ is correct per design step area; issue scope
  section is silent on DSEND-1's test location.
