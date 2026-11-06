# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 3)

All acceptance tests pass. No actionable changes needed this iteration.

## Changes made in previous iterations (intact)

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.

## Acceptance test results (verified iteration 3)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 14/14 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |

## Shape-floor findings 1-9

**All in-scope shape-floor test files pass.** All test files using `_TPL_STAGES[N]` are correct:
- tests/unit/shape-floor-content-stable-test.sh → 7/7 pass
- tests/unit/shape-floor-summary-plain-test.sh → 7/7 pass
- tests/unit/core-pipeline-template-test.sh → 74/74 pass
- tests/unit/build-oos-pass-request-test.sh → 15/15 pass
- tests/unit/template-simple-yaml-test.sh → 84/84 pass
- tests/unit/template-resolvability-preflight-test.sh → 15/15 pass
- tests/unit/change-scope-floor-test.sh → 5/5 pass

**Golden files** (tests/golden/full-pipeline/event-sequence.golden, tests/golden/parity/event-sequence.golden):
- These files are still correct. My implementation only adds events on RESUME paths
  (pipeline.resume, artifact.snapshot.saved on resume); fresh-run event sequences are unaffected.
- The shape-floor check fails with `missing_floor_files` because `_SF_VERIFY_OK=0`
  (stage-retry-test.sh has 15 pre-existing failures that block golden file verification via
  `_sf_floor_verified`). This is NOT caused by my changes.

**Explanation of shape-floor failure:**
- The shape-floor check requires either: (a) floor files in the diff with real changes, OR
  (b) `_SF_VERIFY_OK=1` and `_SF_FAILED_COUNT=0` (zero test failures).
- stage-retry-test.sh has 15 pre-existing failures (from issue #2439, commits 9350c5e4/f03de783).
- stage-retry-test.sh does NOT source runner.sh, cycle-orchestrator.sh, artifact-persist.sh,
  or hydrate/plugin.sh — none of this issue's scope files.
- Therefore `_SF_FAILED_COUNT > 0` → golden files cannot be verified → shape-floor FAIL.
- Fixing this would require either fixing stage-retry-test.sh (out of scope) or making
  unnecessary changes to the golden files (incorrect — my changes don't alter fresh-run events).

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail — pre-existing from issue #2439
  - Sources: helpers.sh, test-helpers.sh, registry.sh, template.sh, verdict.sh, strategies/common.sh
  - Does NOT source any file in issue-1805's scope
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing

## Issue-acceptance findings (from timeout iter-2-attempt-2)

Finding 1 (R-13) & Finding 2 (R-14): The claim that "dispatch-unit loop changes regress retry
behavior" is INCORRECT. stage-retry-test.sh does not source runner.sh or any scope file.
The failures are pre-existing from issue #2439.
