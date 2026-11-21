# Test Author Notes — DSCLA tests (issue 1764)

## Status: COMPLETE (iteration 16 — TAFND-10 fixed)

All test files are written and in place. All SPECs have assertions.

## Changes made in this run (iteration 16)

### Fixed TAFND-10 (DSCLA-3/9): missing cleanup for _ZBUILD_CLAIM_HOLDER

**File:** `plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`

**Problem:** `_ZBUILD_CLAIM_HOLDER` is set as a side effect of `zbuild_claim_acquire "$_dscla4_issue"`
in the DSCLA-3/DSCLA-9 block (the second DSCLA-3 block that uses the rsc_render_header fixture).
The [DSCLA-9] Then assertions check its value, but no `# Cleanup` section unsets it afterward.
It remained set until DSCLA-8's Given called `unset _ZBUILD_CLAIM_HOLDER` at a different block,
creating hidden state leakage between test blocks.

**Fix:** Added a `# Cleanup` section after the last [DSCLA-9] Then assertion with:
```bash
# Cleanup: unset _ZBUILD_CLAIM_HOLDER set as a side effect of zbuild_claim_acquire above
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
```

## Previous iteration key changes (kept for reference)

- iteration 15: Fixed TAFND-7 (DSCLA-2 cleanup), TAFND-8 (DSCLA-7 untagged guard), TAFND-9 (DSCLA-13 untagged guard)
- iteration 14: Fixed TAFND-5 (DSCLA-8) and TAFND-6 (DSCLA-17) — replaced indirect gh-count
  proxy with direct stub hook-not-called checks
- iteration 13: Fixed RLCORRECTNESS-2 / RLSCOPE-1 — rsc_render_header generates run-status
  comment fixture (not hand-written); wrote DSCLA-23
- iteration 12: Fixed DSCLA-19 (correct issue number forwarded); updated golden event-sequence
- iteration 11: Fixed DSCLA-19 to use explicit stub coordinator

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
