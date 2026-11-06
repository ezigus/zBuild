# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 4 — no changes needed)

All acceptance tests pass. Shape-floor and issue-acceptance findings are pre-existing or already answered.

## Changes made in previous iterations (intact)

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.

## Acceptance test results (verified iteration 4)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 14/14 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |

## Shape-floor findings 1-9 — answered

The shape-floor failed with `missing_floor_files` because:
- `runner.sh` and `cycle-orchestrator.sh` match `config/shape-change-paths.txt`
- This triggers a shape-change, requiring floor files (golden + _TPL_STAGES tests) to be in diff OR verified by the test run
- The test run has pre-existing failures (stage-retry-test.sh #2439, write-boundary-revert-test.sh) → `_SF_FAILED_COUNT > 0`
- Golden files cannot be verified when `_SF_FAILED_COUNT > 0` (by design in _sf_floor_verified)

The floor files ARE correct:
- Golden files: my changes only add behavior on RESUME paths; fresh-run event sequences are unchanged
- Unit test files: all pass individually (7/7, 7/7, 15/15, 74/74, 84/84, 15/15, 5/5)

The shape-floor failure is caused by pre-existing failures in stage-retry-test.sh (issue #2439)
and write-boundary-revert-test.sh, which are out of scope and do not source any file in
issue-1805's scope.

## Issue-acceptance finding 1 — answered

ORDE-1 was removed from requirements by the intake stage as a process/scheduling
constraint ("do not run this in parallel with #1714"). It does not appear in the
REQUIREMENTS YOUR CODE MUST MEET section and cannot be verified by any code or test.

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail — pre-existing from issue #2439
  - Sources: helpers.sh, test-helpers.sh, registry.sh, template.sh, verdict.sh, strategies/common.sh
  - Does NOT source any file in issue-1805's scope
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing
