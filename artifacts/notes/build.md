# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status
Starting fresh analysis from test stage failures. Previous build timed out.

## Key failures from test stage

### 1. cycle-orchestrator UNCONDITIONAL current_iter read (NOT YET FIXED)
File: core/pipeline/cycle-orchestrator.sh ~line 2325-2329
Bug: reads current_iter from state regardless of resume mode, breaking nested loops.
Fix: guard with `if [[ "${_ZBUILD_RESUME_ACTIVE:-false}" == "true" ]]`

### 2. stage.start DOUBLE-EMIT from _cycle_dispatch_stage
Bug: A stage.start emit was added inside _cycle_dispatch_stage for cycle members,
causing double-emit and breaking stop-run-on-fail, write-boundary-revert, stage-retry.
Fix: remove the extra stage.start emit from _cycle_dispatch_stage

### 3. runner.sh needs `export _ZBUILD_RESUME_ACTIVE=true` after _runner_resume_rehydrate

### 4. shape-floor: golden files and some tests may need updating

## Files I CAN touch (scope for this build stage)
- core/pipeline/runner.sh
- core/state/artifact-persist.sh  
- plugins/tool/hydrate/plugin.sh
- core/pipeline/cycle-orchestrator.sh
- docs/adr/ADR-006-resume-contract.md
- docs/adr/ADR-050-prior-work-reuse-contract.md
- tests/integration/pipeline-resume-test.sh
- tests/integration/resume-after-sigint-test.sh
- tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
- tests/integration/nested-loop-rounds-test.sh
- tests/integration/nested-loop-rounds-build-test.sh
- tests/integration/cycle-member-dispatch-events-test.sh
- tests/golden/full-pipeline/event-sequence.golden
- tests/golden/parity/event-sequence.golden
- tests/unit/core-pipeline-template-test.sh
- tests/unit/shape-floor-content-stable-test.sh
- tests/unit/shape-floor-summary-plain-test.sh
- tests/unit/build-oos-pass-request-test.sh
- tests/unit/template-simple-yaml-test.sh
- tests/unit/template-resolvability-preflight-test.sh
- tests/unit/change-scope-floor-test.sh

## Files I CANNOT touch (acceptance tests - read only)
- tests/integration/resume-rehydrate-test.sh
- tests/integration/from-stage-rehydrate-test.sh
- tests/integration/resume-loop-state-test.sh
- tests/integration/resume-entry-points-test.sh
- tests/unit/hydrate-stage-test.sh
