# test-author notes — issue #1805 (round 2 fix, final pass)

## Status: fixing resume-entry-points-test.sh SPEC-13 (this call)

## Round-2 checker finding for resume-entry-points-test.sh

### SPEC-13 (resume-entry-points-test.sh)
Finding:
- "only check fixture file content — they do not check that a pipeline containing that cyclic
  stage was actually run within those sections; the run evidence for those two files is tagged
  to SPEC-12 and SPEC-7 respectively, so the 'uses a pipeline' half of the requirement is only
  directly established by SPEC-13 assertions for two of the four files."

What is wrong:
- The current SPEC-13 section (lines 287-296) asserts that intake dispatched (stage.start count).
  But intake dispatches in ANY pipeline — this does not prove the cyclic stage ran.
- Missing: assertion that the `cycled` stage was dispatched, which proves the cyclic portion
  of the pipeline actually executed.

Fix:
- After the existing intake-starts assertion, add:
  `_s13_ep_cycled_starts` count of `stage.start` events where `.data.stage == "cycled"`
  then `assert_gt` that count is > 0
- This proves the pipeline executed the cyclic stage, not just a non-cyclic stage.
- Fixture: artifact-snapshot-coverage has `cycled` stage in the cycle body.
- Mock for `cycled` is already set up at line 41 (mock_plugin_factory "cycled" "agent" 0 "" "builder").
- assert_gt signature: assert_gt desc actual threshold → checks `actual -gt threshold`
  So: `assert_gt "desc" "$_s13_ep_cycled_starts" "0"`

## Previous files (already correct)

### from-stage-rehydrate-test.sh
- SPEC-3: file exists + content matches + no intake.start + build first ✓
- SPEC-4: exit 1 + stderr names stage + no stage.start ✓
- SPEC-13: type: cycle check + pipeline actually ran (intake + cycled dispatched) ✓

### resume-loop-state-test.sh
- SPEC-7: cycle_dispatch_stage current_iter starts from persisted value, not 1 ✓
- SPEC-13: type: cycle check + assert_gt _SPEC7_FIRST_ITER > -1 ✓

### resume-rehydrate-test.sh
- SPEC-1: all 3 paths use rehydration + complete stage emits no stage.start ✓
- SPEC-2: absent artifact → exit 1 + no stage.start ✓
- SPEC-5: ADR-006 has "3.6" + "_runner_resume_rehydrate" ✓
- SPEC-6: ADR-050 §6 has "new run" + "ADR-006" + "continues the same run" ✓
- SPEC-12: fresh run: intake dispatched + cycled dispatched (cycle enabled) ✓
- SPEC-13: type: cycle + pipeline ran ✓

## SPEC coverage summary (all files):
- SPEC-1: resume-rehydrate-test.sh
- SPEC-2: resume-rehydrate-test.sh
- SPEC-3: from-stage-rehydrate-test.sh
- SPEC-4: from-stage-rehydrate-test.sh
- SPEC-5: resume-rehydrate-test.sh
- SPEC-6: resume-rehydrate-test.sh
- SPEC-7: resume-loop-state-test.sh
- SPEC-9: resume-entry-points-test.sh
- SPEC-12: resume-rehydrate-test.sh
- SPEC-13: all 4 files
