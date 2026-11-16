# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (all findings answered in pass 2)

## Files written (verified correct)

### 1. `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
Contains: DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-4, DSCLA-8

All DSCLA tests use `zbuild_claim_acquire` (new function that doesn't exist in base code).
On base code, function not found → rc=127 → all assertions fail correctly.

**Changes in pass 2:**
- DSCLA-2 CI sub-case (after first assert_eq): added `# Given`, `# When`, `# Then`, `# Cleanup` section comments
- DSCLA-8: changed `# Restore backend` to `# Cleanup: restore previous backend and plain gh mock`

**Test structure:**
- Pre-existing tests: old interface (`claim_coordinator_claim`, etc.) using local-fs backend
- DSCLA-1: local-fs backend, issue 1001, verifies `zbuild:claimed` label added (no hostname)
- DSCLA-2 (main case): gh backend with recording mock, verifies comment has run_id+machine
- DSCLA-2 (CI sub-case): gh backend GITHUB_ACTIONS=true, verifies CI URL; now has Given/When/Then/Cleanup
- DSCLA-3: local-fs backend with pre-populated `zbuild:claimed`, verifies returns 1
- DSCLA-4: local-fs backend with holder.txt, verifies `_ZBUILD_CLAIM_HOLDER` set
- DSCLA-8: gh backend with recording mock, verifies no calls for empty issue

**Why DSCLA-1/DSCLA-3 "no stage dispatched / runner exits non-zero" are NOT in unit test:**
- The unit test tests `zbuild_claim_acquire` as a function only — no runner machinery
- "No stage dispatched" and "runner exits non-zero" are runner-integration concerns
- Covered in teardown-repeat-signal-test.sh:
  - DSCLA-1 "before dispatch": `[DSCLA-1/5]` marker — stage checks label present at dispatch time
  - DSCLA-3 "runner exits non-zero, no stage dispatched": DSCLA-9 test section in teardown test

### 2. `tests/integration/teardown-repeat-signal-test.sh`
Contains: DSCLA-1 (via `[DSCLA-1/5]` tag), DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9

**Changes in pass 1:**
1. Removed spurious `print_test_results; exit "$FAIL"` between T5 and DSCLA section (caused exit 6 on base code)
2. Fixed `claim-test.yaml` template from old-shape (`stages:`) to new-shape (`flow:`)

**Changes in pass 2:**
1. DSCLA-5 "absent after exit": gated on `_DSCLA5_PRESENT` — fails on base code because
   `zbuild_claim_acquire` never runs → marker never created → assertion fails (was vacuous pass)
2. DSCLA-5: added "comment shows finished" assertion checking
   `$ZBUILD_CLAIM_STORE/$_DSCLA5_ISSUE/comment.txt` for "finished" word
3. DSCLA-6 "absent after failure": same gate pattern on `_DSCLA6_PRESENT`
4. DSCLA-6: added "comment shows finished" assertion for `comment.txt`
5. DSCLA-7 "absent after TERM": same gate pattern on `_DSCLA7_PRESENT`
6. DSCLA-7: added "comment shows finished" assertion for `comment.txt`

**How each DSCLA test fails on base code (after pass 2 fixes):**
- DSCLA-1/5: stage never writes `$_DSCLA5_PRESENT` → `[DSCLA-1/5]` FAILS ✓
- DSCLA-5 "absent": `_DSCLA5_PRESENT` absent → gates to `assert_fail "[DSCLA-5] was never acquired"` ✓
- DSCLA-5 "comment": `comment.txt` doesn't exist → grep fails → `assert_fail` ✓
- DSCLA-6 "was present": `_DSCLA6_PRESENT` absent → `[DSCLA-6] was present during failure run` FAILS ✓
- DSCLA-6 "absent": gates to `assert_fail "[DSCLA-6] was never acquired"` ✓
- DSCLA-6 "comment": no `comment.txt` → `assert_fail` ✓
- DSCLA-7 "was present before stage": `_DSCLA7_PRESENT` absent → FAILS ✓
- DSCLA-7 "absent": gates to `assert_fail "[DSCLA-7] was never acquired"` ✓
- DSCLA-7 "comment": no `comment.txt` → `assert_fail` ✓
- DSCLA-9: runner doesn't check `zbuild:claimed` → dispatches stage (marker created) → exits 0,
  no holder in output → all three DSCLA-9 assertions FAIL ✓

**DSCLA test infrastructure:**
- One shared `_CLAIM_REPO` git repo with `claim-test.yaml` template
- Template: `flow: [outcome]`, `always_run: []` (verbatim, no inheritance from simple)
- Backend: `ZBUILD_CLAIM_BACKEND=local-fs`, `ZBUILD_CLAIM_STORE=$TEST_TEMP_DIR/claim-store-dscla`
- `ZBUILD_NO_WORKTREE=1`, `ZBUILD_NO_ISSUE_LOCK=1` to prevent git/flock ops
- Stage plugin overwritten per scenario; checks for `zbuild:claimed` in claim store before writing markers

**Issue numbers used (reserved range 90000000+):**
- DSCLA-5: issue 90001764
- DSCLA-6: issue 90001765
- DSCLA-7: issue 90001766
- DSCLA-9: issue 90001767

## Interface assumptions for new code

New function `zbuild_claim_acquire <issue>` in plugin.sh:
- Returns 0: claim acquired → writes `zbuild:claimed` to `$ZBUILD_CLAIM_STORE/<issue>/labels.txt`
  AND writes holder info to `$ZBUILD_CLAIM_STORE/<issue>/holder.txt`
  AND writes initial comment body to `$ZBUILD_CLAIM_STORE/<issue>/comment.txt`
- Returns 1: claim already held → sets `_ZBUILD_CLAIM_HOLDER` from `$ZBUILD_CLAIM_STORE/<issue>/holder.txt`
- Returns 0 (early): when issue is empty

New function `zbuild_claim_release <issue>` in plugin.sh (called by runner EXIT trap):
- Removes `zbuild:claimed` from `$ZBUILD_CLAIM_STORE/<issue>/labels.txt`
- Writes content containing "finished" to `$ZBUILD_CLAIM_STORE/<issue>/comment.txt`
  (e.g. "finished: run-X on machine-Y")

For gh backend:
- `issue:view:*` returns labels list (no `zbuild:claimed` → empty)
- `issue:edit:*` to add/remove label
- `issue:comment:create` or `issue:comment:*` to post holder comment with run_id+machine (or CI URL)

Runner changes:
- Sources the claim-coordinator plugin
- Calls `zbuild_claim_acquire <issue>` before first stage dispatch
- Calls `zbuild_claim_release <issue>` in `_runner_abort_trap` (EXIT trap)
- If `zbuild_claim_acquire` returns 1, runner exits non-zero before dispatch, prints `_ZBUILD_CLAIM_HOLDER`
