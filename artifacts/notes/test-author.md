# test-author notes — issue #1805 (round 63)

## Status: ALL SPECS COVERED — LOOP_COMPLETE

All 17 SPECs have passing assertions written and verified on disk. 887 tests
passed on the last test run. All open findings from previous rounds have been
answered.

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
- DSFSTG-1 ✓: --from-stage ID reader returns correct stage name

### tests/integration/pipeline-resume-test.sh (not a SPEC test file, verified)
- Pre-writes intake artifact before --resume run (DSRHYD-2 compatibility) ✓
- --from-stage without --resume section uses status:"in_progress" with $now timestamp
  (auto-resume condition for RQFROM-4) ✓

## Findings answered this round

### issue-acceptance finding 1
Done in a prior round. The pipeline-resume-test.sh `--from-stage without --resume` section
uses `status:"in_progress"` with `$now` (a recent timestamp that triggers auto_resume
recommendation). Verified on disk: line 324 shows
`plugin_state:{},status:"in_progress",updated_at:$now}' > "$INT_STATE_FILE"`.
RQFROM-4 requires refusal "even when the run would otherwise resume by itself" — this
is the canonical auto-resume trigger. The base code handles this correctly (guard precedes
auto-resume); the branch code that moved the guard to after auto-resume processing regresses
it, and this test now catches that regression.

### lens-correctness-code finding 2
Wrong. DSCMBR-1 GIVEN explicitly states "member stage 'test' was interrupted before
completing; persisted state records test as aborted." Using `stage_statuses.test = "aborted"`
is exactly right for the stated GIVEN. The edge case the finding names — test.status="complete"
from iter N-1 and build already completed in iter N (the all-complete pre-scan path) — is not
stated in any requirement or design spec in this contract and is beyond this issue's acceptance
boundary.

### lens-correctness-design finding 1
Not mine. The finding is about the interaction between `skip_until_stage` and `resume_mode`
inside `core/pipeline/runner.sh` — an implementation file I cannot modify. The DSFSTG-3 test
correctly asserts the observable behavior: stage.start (or cycle.start) is emitted for each
stage after `<s>`, and no stage.skip events fire for any stage after `<s>`.
