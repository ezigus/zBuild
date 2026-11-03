# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE

All acceptance tests pass. All lint checks pass. Pre-existing failures confirmed pre-existing.

## Acceptance test results (verified this iteration)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 35/35 pass (SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14) |
| from-stage-rehydrate-test.sh | ✓ 10/10 pass (SPEC-3, SPEC-4, SPEC-14) |
| resume-loop-state-test.sh | ✓ 3/3 pass (SPEC-7) |
| resume-entry-points-test.sh | ✓ 5/5 pass (SPEC-9) |
| hydrate-stage-test.sh | ✓ 25/25 pass (SPEC-13) |
| pipeline-resume-test.sh | ✓ 23/23 pass |
| cycle-inner-iter-resets-per-outer-iter-test.sh | ✓ 15/15 pass |
| nested-loop-rounds-test.sh | ✓ 11/11 pass |
| nested-loop-rounds-build-test.sh | ✓ 24/24 pass |
| cycle-member-dispatch-events-test.sh | ✓ 8/8 pass |
| resume-after-sigint-test.sh | ✓ 14/14 pass |
| lint-grep-c-test.sh | ✓ 21/21 pass |
| shape-floor-content-stable-test.sh | ✓ 7/7 pass |
| shape-floor-summary-plain-test.sh | ✓ 7/7 pass |

## Pre-existing failures (NOT regressions)

Verified by running tests against base commit 56f4c022 (before any issue-1805 changes):

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail on BASE — pre-existing
- `tests/integration/write-boundary-revert-test.sh`: 2 of 20 fail on BASE — pre-existing

These are NOT caused by issue-1805 changes.

## What was implemented

1. **`_artifact_persist_put_back`** in `core/state/artifact-persist.sh:638`
   - Copy-back helper shared by runner + hydrate plugin

2. **`_runner_resume_rehydrate`** in `core/pipeline/runner.sh:1707`
   - Called at line 2859 after `_zbuild_disarm_abort_sentinel`
   - Restores completed-stage artifacts from git state branch into artifacts dir

3. **`_runner_from_stage_preflight`** in `core/pipeline/runner.sh:1727`
   - Called at line 2949 when `--from-stage` is set
   - Restores artifacts + verifies each pre-target stage has its artifact
   - Handles cycle IDs as from_stage target (finds first member stage)

4. **Dispatch-unit loop stage:* arm** (lines 3722-3768)
   - Skips complete stages on resume (checks stage_statuses)
   - Fail-closed: exits 1 if artifact missing after rehydration
   - Skips pre-target stages for --from-stage

5. **Dispatch-unit loop cycle:* arm** (lines 3435-3455)
   - Skips complete cycles on resume
   - Skips pre-target cycles for --from-stage

6. **`_ZBUILD_RESUME_ACTIVE=true`** export at runner.sh:2862
   - Set after `_runner_resume_rehydrate` for cycle orchestrator

7. **Cycle orchestrator guard** in `core/pipeline/cycle-orchestrator.sh`
   - Guards `current_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]`
   - Fresh runs always start at iter=1

8. **ADR-006 amended** with step 3.6 + enforcing test names

9. **ADR-050 amended** with §6 boundary note

10. **Hydrate plugin** redirected to `_artifact_persist_put_back`

## Findings answers

- test finding 1: not reproduced — from-stage-rehydrate passes 10/10
- test finding 2: not reproduced — resume-rehydrate passes 35/35
- test finding 3: pre-existing — write-boundary-revert D7 fails on base commit
- test finding 4: not reproduced — lint-grep-c passes 21/21
- test finding 5: pre-existing — stage-retry fails 15/24 on base commit

- shape-floor finding 1: nothing to do — my changes don't alter fresh pipeline event sequences
- shape-floor finding 2: nothing to do — same as above

- issue-acceptance finding 1-5: not reproduced — all SPEC tests pass
- issue-acceptance finding 6: not reproduced — D7 and stage-retry failures are pre-existing
- issue-acceptance finding 7: SPEC-7 passes (resume-loop-state-test: 3/3)
- issue-acceptance finding 8: ADR amendments verified present
