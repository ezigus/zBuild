# test-author notes — issue #1805 (round 66)

## Status: ALL SPECS COVERED — LOOP_COMPLETE

All 17 SPECs have passing assertions written and verified on disk.

## What is in each test file

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓: overrides `_artifact_persist_put_back` with sentinel-writing function, runs `hydrate_run`, asserts sentinel was written

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓: artifacts restored byte-identical before dispatch loop
- DSRHYD-2 ✓: missing primary artifact → exit 1 before any stage.start
- DSSKIP-1 ✓: stage marked complete with artifact present → no stage.start in dispatch loop
- DSDSPK-1 ✓: interrupted stage k emits stage.start on resume
- DSFRSH-1 ✓: fresh run dispatches all stages from stage 1, no skip events
- DSFRSH-2 ✓: new run with prior artifacts → all stages dispatched, no stage.skip

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓: --from-stage <s> rehydrates prior stages and dispatches <s> first (S3, S5, S6)
  - S3: `--resume --from-stage cyc` with cycle fixture
  - S5: `--resume --from-stage cyc` with second coverage sub-case
  - S6: `--resume --from-stage build` with leaf stage
- DSFSTG-2 ✓: missing artifact → exit 1 with "has no restorable primary artifact" on stderr
- DSFSTG-3 ✓: combined --resume --from-stage; stages after <s> dispatched despite being complete (S10)
- DSFSTG-4 ✓: --from-stage without --resume exits 1 with "only valid with --resume"
  - S11: flat ZBUILD_STATE_FILE path, status=interrupted (auto-resume conditions met)
  - S12: latest-symlink path, ZBUILD_STATE_FILE/DIR unset via env -u, status=interrupted

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓: cycle orchestrator starts at current_iter=2 on resume (not iter=1)
- DSCMBR-1 ✓: within interrupted iteration, build (complete) skipped; test (aborted) dispatched

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓: all three entry paths (--resume, auto-resume, zbuild pipeline resume) restore artifacts before dispatch
- DSENTR-2 ✓: auto-resume via latest symlink (ZBUILD_STATE_FILE/DIR unset via env -u) → pipeline.resume emitted, artifacts restored

### tests/unit/descriptive-id-readers-test.sh
- Identical to base code (R8 reverted in a prior round; no SPEC assertions from this issue)

### tests/integration/pipeline-resume-test.sh (not a SPEC test file, verified)
- Pre-writes intake artifact before --resume run (DSRHYD-2 compatibility) ✓
- --from-stage without --resume section uses status:"in_progress" with $now timestamp
  (auto-resume condition for RQFROM-4) ✓
- This test FAILS because the implementation in core/pipeline/runner.sh doesn't
  meet RQFROM-4 (the flat-file auto-resume elif fires before the --from-stage guard
  for in_progress state). The test is correct. Fixing the implementation is not in scope.

## Unit test files reverted to base code (round 66)

The following files had changes from base code that tested an unasked run-status-text.sh
rendering change (issue-acceptance finding 3). Reverted all 4 to be identical to base code:
- tests/unit/acceptance-testfile-sections-test.sh
- tests/unit/multiline-assertion-tag-test.sh
- tests/unit/run-status-comment-render-test.sh
- tests/unit/status-row-findings-test.sh

## Why pipeline-resume-test.sh still fails (implementation bug, not test bug)

The test correctly asserts RQFROM-4: "--from-stage without --resume exits 1 even when
auto-resume conditions (in_progress) are present." The implementation doesn't meet it because
the flat-file auto-resume elif in runner.sh fires for `in_progress` state before the guard.
The test is correct; the implementation needs fixing in core/pipeline/runner.sh (not in scope
for test-author).

## Findings answered

### issue-acceptance finding 1
Not mine. The test correctly asserts RQFROM-4. The implementation doesn't meet it.
Fixing runner.sh is outside test-author scope.

### issue-acceptance finding 3
Done. Reverted all 4 test files (acceptance-testfile-sections-test.sh,
multiline-assertion-tag-test.sh, run-status-comment-render-test.sh,
status-row-findings-test.sh) to their base code versions. These files had changes
that tested an unasked run-status-text.sh rendering change. All 4 now pass diff -eq 0
against base code.

### lens-correctness-code finding 2
Wrong. DSCMBR-1 uses `aborted` per the GIVEN ("persisted state records test as aborted").
The all-complete edge case is not named by any requirement in this issue.

### lens-correctness-design finding 1
Not mine. The finding is about skip_until_stage and resume_mode interaction in runner.sh.
DSFSTG-3 correctly asserts the observable behavior.
