# Test Author Checkpoint — Issue #1801 (Iteration 2)

## Status: FIXING FAILURES from iteration 1

## Problems identified from test run output

### 1. orch-sequential-retired-guard-test.sh (SPEC-8)
- Guard excludes itself but not tests/unit/orch-backend-misconfigured-test.sh
- That file references "orch-sequential" in historical commentary (lines 6-7, 62)
- SPEC-8 explicitly says this file is excluded from the guard
- Fix: add grep -v exclusion for orch-backend-misconfigured-test.sh

### 2. event-schema-emitted-coverage-test.sh (SPEC-18)
- No [#1801/SPEC-18] assertions present for orch.backend.misconfigured and plugin.run.timed_out
- The general coverage test fails because these types are emitted but not registered
- Fix: add explicit SPEC-18 assertions checking _engine_types for both types

### 3. design-prompt-scope-charter-test.sh (T6 existing check)
- T6 greps first timeout_s: in design block, expects 600
- After change: stage_timeout_s: 3900 precedes router.timeout_s: 600, so gets 3900
- Fix: change T6 to grep for stage_timeout_s specifically and assert value is 3900

### 4. stage-timeout-dispatch-test.sh (SPEC-17 tautology)
- SPEC-17 is NOT in the contract requirements for this issue
- Previous iteration added [#1801/SPEC-17] tags
- Acceptance gate flags them as tautology (checking if file exists always passes)
- Fix: REMOVE the [#1801/SPEC-17] tag prefix from assertions, keep assertion text

## What I would do next if stopped
- All 4 fixes are the full work needed for this iteration
