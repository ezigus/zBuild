# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Twenty-third pass — DISP-1 added for RESU-3/RESU-4 "stage k is dispatched" gap

### Root cause of twenty-second-pass failure

Two findings from the checker:
1. RESU-3 not covered: SKIP-1 covers skipping already-complete stages k-1, but no SPEC has a Then asserting stage k is dispatched.
2. RESU-4 not covered: RHYD-1 covers outputs present and no dispatch of 1…k-1; SKIP-1 covers the skip; but no SPEC has a Then asserting stage k emits stage.start.

SKIP-1 and RHYD-1 jointly covered the "skip complete stages" and "artifacts present" aspects, but the "stage k is dispatched" clause of both RESU-3 and RESU-4 had no SPEC with an observable Then:.

### Changes in this pass

1. **Added DISP-1[code]**: "On resume, stage k (the interrupted stage) is dispatched and emits stage.start."
   - Given: stages 1…k-1 are complete with artifacts present after rehydration
   - When: dispatch loop reaches stage k
   - Then: stage k emits a stage.start event
   - covers: RESU-3 RESU-4
   - TESTFILES: tests/integration/resume-rehydrate-test.sh

2. **Updated step 10**: Added item (6) — add [#1805/DISP-1] assertion in resume-rehydrate-test.sh verifying stage k emits stage.start.

3. **Updated TESTFILES**: Added `DISP-1: tests/integration/resume-rehydrate-test.sh`.

4. **Updated Finding 3**: RESU-3 now covered by SKIP-1, DISP-1. RESU-4 now covered by RHYD-1, SKIP-1, DISP-1.

5. **Updated Finding 1**: Added DISP-1 to the SPEC ID listing.

6. **Added Finding 13**: Documents this change.

### Behavioral basis for DISP-1

runner.sh:3895-3927: skip guard applies only when `stage_status == "complete"`. Stage k (the interrupted stage) has status not equal to "complete" (it was interrupted mid-execution), so the `continue` is NOT executed. The loop falls through to runner.sh:3937: `eb_emit_event "stage.start" "stage=$stage"`. This is existing behavior; DISP-1[code] requires a test to make it explicit in the acceptance contract.

### Implementation state (verified)

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- In-loop exit-1 for missing artifacts at runner.sh:3920 (ADR-006 §3.6 comment) ✓
- comment "When resuming, skip stages already marked complete…" at runner.sh:3895 ✓
- `if $resume_mode; then` at runner.sh:2845 gates the entire rehydration block ✓
- Stage k dispatch: skip guard only for `stage_status == "complete"`; stage k falls through to `eb_emit_event "stage.start"` at runner.sh:3937 ✓

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with `_ZBUILD_RESUME_ACTIVE` needed (step 6)
- resume-loop-state-test.sh needs `export _ZBUILD_RESUME_ACTIVE=true` before `cycle_orchestrator_run` call (step 9)

### SPEC summary (twenty-third pass)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 ORDE-1 |
| AMDR-2 | [no-code] | ADR-2 |
| ITER-1 | [code] | LOOP-1 |
| SKIP-1 | [done] | RESU-3 RESU-4 |
| DISP-1 | [code] | RESU-3 RESU-4 |
| ENTR-1 | [code] | PATH-1 |
| FRSH-1 | [no-code] | GUAR-1 |
| FRSH-2 | [done] | GUAR-2 |
| BNDY-1 | [no-code] | ADR-2 |
| DLGT-1 | [code] | HYDR-1 |
| CYCL-1 | [no-code] | TEST-1 |

**Counts: 8 [code], 2 [done], 5 [no-code], 0 REMOVED**

### Requirement → SPEC mapping (all 16 covered)

| Requirement | SPEC(s) |
|-------------|---------|
| RESU-1 | RHYD-1 |
| RESU-2 | RHYD-1, RHYD-2 |
| RESU-3 | SKIP-1, DISP-1 |
| RESU-4 | RHYD-1, SKIP-1, DISP-1 |
| FROM-1 | FSTG-1 |
| FROM-2 | FSTG-1 |
| FROM-3 | FSTG-2 |
| LOOP-1 | ITER-1 |
| PATH-1 | ENTR-1 |
| GUAR-1 | FRSH-1 |
| GUAR-2 | FRSH-2 |
| ADR-1 | AMDR-1 |
| ADR-2 | AMDR-2, BNDY-1 |
| HYDR-1 | RHYD-1, DLGT-1 |
| TEST-1 | CYCL-1 |
| ORDE-1 | AMDR-1 |
