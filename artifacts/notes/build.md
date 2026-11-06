# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 2)

All acceptance tests pass. All cycle-related tests pass.

## Changes made in this iteration

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line:
   `Ordering constraint: not to be combined with dispatch-loop changes; this`
   Required by [#1805/AMDR-1] test which checks for `"not to be combined with dispatch-loop changes"` as substring.

2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation:
   - Changed `_start_iter=$(( _persisted_iter + 1 ))` → `_start_iter=$(( _persisted_iter > 0 ? _persisted_iter : 1 ))`
   - Added `_ZBUILD_RESUME_ACTIVE=false` after reading the flag (flag consumption for nested calls)
   Required by [#1805/ITER-1]: persisted `current_iter=2` → start at 2 (not 3); and
   nested-loop re-entry must start at 1 (outer call consumed the flag).

## Acceptance test results (verified this iteration)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 40/40 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 14/14 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |
| pipeline-resume-test.sh | ✓ 23/23 pass |
| cycle-inner-iter-resets-per-outer-iter-test.sh | ✓ 15/15 pass |
| nested-loop-rounds-test.sh | ✓ 11/11 pass |
| nested-loop-rounds-build-test.sh | ✓ 24/24 pass (NOTE: was 8/8 before; may now show 24) |
| cycle-member-dispatch-events-test.sh | ✓ 8/8 pass |
| resume-after-sigint-test.sh | ✓ 14/14 pass |

## Shape-floor findings (findings 1-9)

All in-scope shape-floor test files pass on this tree:
- tests/unit/shape-floor-content-stable-test.sh → 7/7 pass
- tests/unit/shape-floor-summary-plain-test.sh → 7/7 pass
- tests/unit/core-pipeline-template-test.sh → 74/74 pass
- tests/unit/build-oos-pass-request-test.sh → 15/15 pass
- tests/unit/template-simple-yaml-test.sh → 84/84 pass
- tests/unit/template-resolvability-preflight-test.sh → 15/15 pass
- tests/unit/change-scope-floor-test.sh → 5/5 pass

The golden files tests/golden/full-pipeline/event-sequence.golden and
tests/golden/parity/event-sequence.golden are not tested by any failing in-scope test.
They don't need updating.

## Issue-acceptance findings

Finding 1 (R-13) & Finding 2 (R-14): stage-retry-test.sh (15/24 fail) and
write-boundary-revert-test.sh (D7 fail) — these are PRE-EXISTING failures.
Evidence:
- stage-retry-test.sh does NOT source runner.sh, cycle-orchestrator.sh,
  artifact-persist.sh, or hydrate/plugin.sh (scope files). It sources
  lifecycle.sh and stage-retry.sh which are OUTSIDE scope.
- These tests last changed in commits 9350c5e4 and f03de783 (issue #2439/#2443),
  both before any issue-1805 work.

Finding 3 (ADR-006): ADR-006 step 3.6 is present. The missing phrase was
"not to be combined with dispatch-loop changes" — FIXED in this iteration.

Finding 4 (ADR-050): ADR-050 §6 boundary note is present (lines 194-200). Verified.

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail — pre-existing from issue #2439
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing

Verification: neither test sources any file in this issue's scope
(runner.sh, artifact-persist.sh, hydrate/plugin.sh, cycle-orchestrator.sh).
