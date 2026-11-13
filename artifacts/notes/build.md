# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 36 — All acceptance tests pass; issue-acceptance finding fixed

## Changes made this iteration (iteration 36)

### issue-acceptance finding 1 — Remove state.write event from cycle_state_write_iter_start failure path

Removed `eb_emit_event "state.write"` (with `op=iter_start`, `cycle_id=...`, `iter=...`,
`reason=write_failed`) from the `_cycle_state_write_iter_start` failure path in
`core/pipeline/cycle-orchestrator.sh`. The failure handler simplified to just the warn call.

This event was added in a previous iteration in response to a lens-sre finding, but
the issue-acceptance stage correctly identified that no requirement (RQLOOP-1, DSITER-1,
or any other) asks for a machine-readable event on this failure path.

## Verification results (iteration 36)

All 5 acceptance test files pass:
- tests/integration/from-stage-rehydrate-test.sh — 35 tests (all pass)
- tests/integration/resume-entry-points-test.sh — 18 tests (all pass)
- tests/integration/resume-loop-state-test.sh — 11 tests (all pass)
- tests/integration/resume-rehydrate-test.sh — 51 tests (all pass)
- tests/unit/hydrate-stage-test.sh — 25 tests (all pass)
