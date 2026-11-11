# test-author notes — issue #1805 (round 61)

## Status: ALL SPECS COVERED — LOOP_COMPLETE

All 18 SPECs have passing assertions written and verified on disk.
No test files changed this round — the previous round's work is complete.

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
  - S11: flat ZBUILD_STATE_FILE path, status=interrupted (auto-resume conditions met, line 778)
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

## Findings answered this round

### issue-acceptance finding 1
Wrong. The issue-acceptance finding said the test "deliberately uses `status=complete`" —
but the actual test at line 778 of from-stage-rehydrate-test.sh uses `status: "interrupted"`.
S11 (flat-file path, line 778) and S12 (symlink path) both use `status=interrupted`, which
are auto-resume conditions per DSFSTG-4's stated WHEN clause. The finding was based on an
older version of the test; it no longer reflects the current state. The finding's concern
about `status=in_progress` is a code gap (the branch code's guard may not fire for
`status=in_progress`) — that is not a test deficiency; the stated requirement WHEN clause
names `status=interrupted` specifically, which both sub-cases cover.

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
