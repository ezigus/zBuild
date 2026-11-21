# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (iteration 14 — TAFND-5 / TAFND-6 fixed)

All test files are written and in place. All SPECs have assertions.

## Changes made in this run (iteration 14)

### Fixed TAFND-5 (DSCLA-8): direct stub hook-not-called check

**File:** `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`

**Problem:** The old DSCLA-8 Then assertion counted gh calls (indirect proxy). A coordinator
claim hook that is invoked but returns early for an empty issue without calling gh would
produce 0 gh calls and pass while the hook was still called.

**Fix:** Replaced the gh-call-count indirect proxy with a stub-coordinator approach:
1. Create a stub plugin in `$TEST_TEMP_DIR/plugins-dscla8/` with unique function names
   (`_dscla8_stub_claim`, etc.)
2. The stub's claim hook writes the received argument to `$TEST_TEMP_DIR/dscla8-hook-called`
   before returning (so it's detectable even if it were to return early)
3. Source the stub and set `ZBUILD_PLUGINS_ROOT` to the stub's plugins root
4. Call `zbuild_claim_acquire ""`
5. Assert marker file was NOT created (hook was never entered)

**Red step on base code:** `core/claim/claim.sh` does not exist on base code.
`zbuild_claim_acquire` is not defined → `zbuild_claim_acquire ""` exits non-zero →
`assert_eq "[DSCLA-8] zbuild_claim_acquire returns 0 for empty issue" "0" "$_dscla8_rc"` fails.

### Fixed TAFND-6 (DSCLA-17): direct stub release hook-not-called check

**File:** `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`

**Problem:** The old DSCLA-17 Then assertion counted gh calls (indirect proxy). A coordinator
release hook that is invoked but detects `_ZBUILD_CLAIM_ACQUIRED` is unset and returns early
without calling gh would produce 0 gh calls and pass while the hook was still called.

**Fix:** Replaced the gh-call-count indirect proxy with a stub-coordinator approach (inside
the existing `if [[ -f "$_dscla17_claim_sh" ]]` else block):
1. Create a stub plugin in `$TEST_TEMP_DIR/plugins-dscla17/` with unique function names
   (`_dscla17_stub_release`, etc.)
2. The stub's release hook writes a marker to `$TEST_TEMP_DIR/dscla17-hook-called`
3. Source the stub and set `ZBUILD_PLUGINS_ROOT` to the stub's plugins root
4. Ensure `_ZBUILD_CLAIM_ACQUIRED` is not set
5. Call `zbuild_claim_release`
6. Assert marker file was NOT created (hook was never entered)

**Red step on base code:** `core/claim/claim.sh` does not exist on base code →
outer `if [[ ! -f "$_dscla17_claim_sh" ]]` gate fires
`assert_fail "[DSCLA-17] core/claim/claim.sh must exist"`.

## Previous iteration key changes

- iteration 13: Fixed RLCORRECTNESS-2 / RLSCOPE-1 — `_dscla4_issue` block now uses
  `rsc_render_header` to generate run-status-comment fixture; wrote DSCLA-23
- iteration 12: Fixed DSCLA-19 to verify correct issue number forwarded to hook (TAFND-4);
  updated golden event-sequence for new claim/release events (IAFND-1)
- iteration 11: Fixed DSCLA-19 to use explicit stub coordinator (TAFND-3)

## Full SPEC coverage

- DSCLA-1: unit test + teardown (claim present before first stage)
- DSCLA-2: unit test (rsc_render_header with holder, CI URL in holder)
- DSCLA-3: unit test + teardown (non-zero exit, no stage dispatched, event emitted)
- DSCLA-5: teardown (zbuild:claimed absent after normal completion)
- DSCLA-6: teardown (zbuild:claimed absent after failure)
- DSCLA-7: teardown (zbuild:claimed absent after TERM)
- DSCLA-8: unit test (stub coordinator; hook not called for empty issue; rc=0)
- DSCLA-9: teardown + unit _dscla4_issue block (holder in output; fixture from rsc_render_header)
- DSCLA-10: unit test (eb_compose_known_types check fails on base code)
- DSCLA-11: teardown ([done] requirement — passes on old and new code)
- DSCLA-12: unit test (CI URL in zbuild-holder comment)
- DSCLA-13: teardown (zbuild:claimed absent after second SIGTERM during abort trap)
- DSCLA-15: teardown (literal \n preserved in output)
- DSCLA-16: teardown (zbuild:claimed absent after _runner_enter_worktree failure)
- DSCLA-17: unit test (stub coordinator; release hook not called when _ZBUILD_CLAIM_ACQUIRED not set)
- DSCLA-18: unit test (claim_coordinator_claim adds zbuild:claimed, no hostname)
- DSCLA-19: unit test (stub with unique names; marker file contains issue number;
  no direct gh calls from zbuild_claim_acquire)
- DSCLA-20: unit test (claim_coordinator_release removes zbuild:claimed, no hostname)
- DSCLA-21: unit test (zbuild_claim_release delegates to coordinator, no direct gh)
- DSCLA-22: teardown integration (stub in ZBUILD_PLUGINS_ROOT; claim before stage;
  release on exit)
- DSCLA-23: unit test (_ccgl_read_holder filters by authenticated actor;
  other user's comment is ignored)
- DSADR-7: lint-adr-enforced-by-test.sh (ADR-005 has Enforced by, not in baseline)

## Test files

- `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
  DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8, DSCLA-9 (unit proxy), DSCLA-10, DSCLA-12,
  DSCLA-17, DSCLA-18, DSCLA-19, DSCLA-20, DSCLA-21, DSCLA-23
- `tests/integration/teardown-repeat-signal-test.sh`
  DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-11, DSCLA-13,
  DSCLA-15, DSCLA-16, DSCLA-22
- `tests/unit/lint-adr-enforced-by-test.sh`
  [#1764/DSADR-7]
- `tests/golden/parity/event-sequence.golden`
  Updated to include new claim/release events (IAFND-1)

## Open findings

None.
