# test-author notes — issue #1805 (round 42: fix lens-scope-code finding 2)

## Status: COMPLETE

## Round 42 changes

### lens-scope-code finding 2 (fix: test) — DONE
Added write-side sub-section for [#1805/DSITER-1] in
`tests/integration/resume-loop-state-test.sh` (inserted between the
"without _ZBUILD_RESUME_ACTIVE" and DSCMBR-1 sections, ~line 197).

The new assertion:
1. Fresh run (no resume, _ZBUILD_RESUME_ACTIVE unset), no prior cycle state
2. Mocks cycle_dispatch_stage to capture current_iter from STATE_FILE at first call
3. Asserts current_iter==1 at first dispatch

Failure logic:
- If _cycle_state_write_iter_start is removed: current_iter stays at init value
  (0 or absent → jq returns -99) → assert "1"=="0" or "1"=="-99" → FAILS ✓
- After the change: write runs before dispatch → current_iter=1 → PASSES ✓

### Not mine (fix: code)
lens-security-code findings 1-4, lens-red-team-code findings 1-3,
lens-correctness-code findings 1-2, lens-scope-code finding 1,
lens-sre-code finding 1 — all require implementation changes; not in test scope.

### Nothing to do
build-tests findings 1 and 2 — confirm the test fixtures are correct per the SPEC.

## All SPECs coverage (all confirmed on disk with correct tags)

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓, DSRHYD-2 ✓, DSAMDR-1 ✓, DSAMDR-2 ✓, DSDSPK-1 ✓
- DSFRSH-1 ✓, DSSKIP-1 ✓, DSFRSH-2 ✓, DSCYCL-1 ✓

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓, DSFSTG-2 ✓, DSCYCL-1 ✓

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓ (read-side + write-side assertions), DSCMBR-1 ✓, DSCYCL-1 ✓

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓, DSENTR-2 ✓, DSCYCL-1 ✓
