# test-author notes — issue #1805 (round 5: from-stage-rehydrate-test.sh confirmation)

## Status: CONFIRMED — from-stage-rehydrate-test.sh already correct; no changes needed

## Round-2 checker findings addressed in this call

### Finding 1: SPEC-3 artifact placement assertions not tagged

**Checker claim:** "`assert_file_exists` and `assert_contains` for 'places their artifacts
in ZBUILD_ARTIFACT_DIR' carry no [#1805/SPEC-3] tag."

**Verification:** Read the current file. Lines 113–115 and 124–126 both carry
`[#1805/SPEC-3]` in their labels:
- Line 114: `"[#1805/SPEC-3] intake-result.json rehydrated into ZBUILD_ARTIFACT_DIR via --from-stage"`
- Line 125: `"[#1805/SPEC-3] restored artifact contains original payload (proves _artifact_persist_restore + _artifact_persist_put_back used git state branch)"`

**Status:** Already resolved by a prior test-author call. No change needed.

### Finding 2: SPEC-4 stderr-naming assertion not tagged

**Checker claim:** "`assert_contains "$_s4_stderr" "intake"` is not tagged with [#1805/SPEC-4]."

**Verification:** Read the current file. Lines 212–214 carry `[#1805/SPEC-4]` in the label:
- Line 213: `"[#1805/SPEC-4] stderr names the missing stage (intake)"`

**Status:** Already resolved by a prior test-author call. No change needed.

## Full SPEC-3 assertion coverage (from-stage-rehydrate-test.sh)

All 4 assertions that together cover the full SPEC-3 requirement are tagged:
1. `assert_file_exists "[#1805/SPEC-3] intake-result.json rehydrated..."` (line 113-115)
   — proves "places their artifacts in ZBUILD_ARTIFACT_DIR"
2. `assert_contains "[#1805/SPEC-3] restored artifact contains original payload..."` (line 124-126)
   — proves `_artifact_persist_restore` + `_artifact_persist_put_back` used git state branch
3. `assert_eq "[#1805/SPEC-3] intake emits no stage.start when skipped via --from-stage"` (line 136-137)
   — proves "emits no stage.start for any earlier stage"
4. `assert_eq "[#1805/SPEC-3] build is the first dispatched stage..."` (line 149-150)
   — proves "dispatches <s> as the first stage"

## Full SPEC-4 assertion coverage (from-stage-rehydrate-test.sh)

All 3 assertions that together cover the full SPEC-4 requirement are tagged:
1. `assert_eq "[#1805/SPEC-4] --from-stage exits 1 when prior stage has no restorable artifact"` (line 207-208)
   — proves "exits 1"
2. `assert_contains "[#1805/SPEC-4] stderr names the missing stage (intake)"` (line 212-214)
   — proves "names the missing stage in stderr"
3. `assert_eq "[#1805/SPEC-4] no stage.start emitted before exit 1"` (line 222-223)
   — proves "before dispatching anything"

## SPEC coverage summary (all test files — unchanged since round 4)

### resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12

**SPEC-1:**
- Path 1: assert_file_exists + assert_contains content + assert_eq build==1 +
          pipeline.resume ordering + assert_eq intake==0
- Path 2: assert_file_exists + assert_contains content + assert_eq build==1 +
          pipeline.resume ordering + assert_eq intake==0
- Path 3: assert_file_exists + assert_contains content + assert_eq build==1 +
          pipeline.resume ordering + assert_eq intake==0

**SPEC-2:** assert_eq rc==1 + assert_eq any_starts==0

**SPEC-5:** assert_contains in ADR-006 for step 3.6, _runner_resume_rehydrate, test names,
          exit 1, "before the dispatch loop", "git state branch"

**SPEC-6:** assert_contains in ADR-050 §6 for "new run", "ADR-006", "continues the same run"

**SPEC-12:** assert_eq intake==1 + assert_contains type:cycle

### from-stage-rehydrate-test.sh — SPEC-3, SPEC-4 (all assertions tagged; no change this round)
### resume-loop-state-test.sh — SPEC-7 (unchanged)
### resume-entry-points-test.sh — SPEC-9 (unchanged)
