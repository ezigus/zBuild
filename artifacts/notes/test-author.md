# test-author notes — issue #1805 (round 62)

## Status: ALL SPECS COVERED — LOOP_COMPLETE

All 18 SPECs have passing assertions written and verified on disk.

One test file was changed this round: `tests/integration/pipeline-resume-test.sh` — the
`--from-stage without --resume` section was restored to use `status:"in_progress"` (the
correct auto-resume condition for RQFROM-4) rather than `status:"complete"` (which the
branch had substituted to hide a code regression).

## What is in each test file

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓: overrides `_artifact_persist_put_back` with sentinel-writing function, runs `hydrate_run`, asserts sentinel was written

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓: artifacts restored byte-identical before dispatch loop
- DSRHYD-2 ✓: missing primary artifact → exit 1 before any stage.start
- DSAMDR-1 ✓: ADR-006 amended with §3.6 and enforcing test names
- DSAMDR-2 ✓: ADR-050 §6 boundary note present with correct Enforced by citations
- DSSKIP-1 ✓: stage marked complete with artifact present → no stage.start in dispatch loop
- DSDSPK-1 ✓: interrupted stage k emits stage.start on resume
- DSFRSH-1 ✓: fresh run dispatches all stages from stage 1, no skip events
- DSFRSH-2 ✓: new run with prior artifacts → all stages dispatched, no stage.skip
- DSCYCL-1 ✓: pipeline fixture contains a stage of type: cycle

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓: --from-stage <s> rehydrates prior stages and dispatches <s> first (S3, S5, S6)
- DSFSTG-2 ✓: missing artifact → exit 1 with "has no restorable primary artifact" on stderr
- DSFSTG-3 ✓: combined --resume --from-stage; stages after <s> dispatched despite being complete (S10)
- DSFSTG-4 ✓: --from-stage without --resume exits 1 with "only valid with --resume"
  - S11: flat ZBUILD_STATE_FILE path, status=interrupted (auto-resume conditions met)
  - S12: latest-symlink path, ZBUILD_STATE_FILE/DIR unset via env -u, status=interrupted
- DSCYCL-1 ✓: pipeline fixture contains a stage of type: cycle (S13)

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓: cycle orchestrator starts at current_iter=2 on resume (not iter=1)
- DSCMBR-1 ✓: within interrupted iteration, build (complete) skipped; test (aborted) dispatched
- DSCYCL-1 ✓: pipeline fixture contains a stage of type: cycle

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓: all three entry paths (--resume, auto-resume, zbuild pipeline resume) restore artifacts before dispatch
- DSENTR-2 ✓: auto-resume via latest symlink (ZBUILD_STATE_FILE/DIR unset) → pipeline.resume emitted, artifacts restored
- DSCYCL-1 ✓: pipeline fixture contains a stage of type: cycle

### tests/unit/descriptive-id-readers-test.sh
- DSFSTG-1 ✓: --from-stage ID reader returns correct stage name

### tests/integration/pipeline-resume-test.sh (not a SPEC test file, but verified)
- Pre-writes intake artifact before --resume run (DSRHYD-2 compatibility) ✓
- --from-stage without --resume test restored to use status=in_progress (auto-resume
  condition) so it correctly expresses RQFROM-4 and catches any code regression that
  moves the guard to after auto-resume processing ✓

## Findings answered this round

### issue-acceptance finding 1
Done. The issue-acceptance finding identified that `pipeline-resume-test.sh` was changed
from `status:"in_progress"` to `status:"complete"` to hide a code regression: the branch
code moved the `--from-stage` without `--resume` guard to AFTER auto-resume processing,
so an `in_progress` run auto-resumes first (setting resume_mode=true) and the guard never
fires. RQFROM-4 says the refusal must happen "even when the run would otherwise resume by
itself" — `in_progress` (recent) is the canonical auto-resume trigger.

Restored the test to use `status:"in_progress"` with a recent timestamp (auto_resume
recommendation). The base code handles this correctly (guard precedes auto-resume); the
branch code regresses it. The test now fails on the branch code and passes on the base code.
The code-stage must move the `--from-stage` guard back before auto-resume processing.

### lens-correctness-code finding 2
Wrong. The DSCMBR-1 requirement GIVEN explicitly names "member stage 'test' was interrupted
before completing; persisted state records test as aborted." Using `stage_statuses.test =
"aborted"` is exactly right for the stated GIVEN. The 'all complete' edge case
(test.status="complete" from a prior iteration) is not stated in any requirement or design
spec in this contract.

### lens-correctness-design finding 1
Not mine. The finding is about the interaction between `skip_until_stage` and `resume_mode`
in `core/pipeline/runner.sh` — an implementation file I cannot modify. The DSFSTG-3 test
correctly asserts the observable behavior: stage.start (or cycle.start) emitted for stages
after <s>, no stage.skip for any stage after <s>.
