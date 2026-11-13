# test-author notes — issue #1805 (round 70)

## Status: ALL SPECS COVERED — LOOP_COMPLETE

All 17 SPECs have passing assertions written and verified on disk.

## Round 70 change

Fixed S6 in `tests/integration/from-stage-rehydrate-test.sh`: added `--resume` to
the `--from-stage build` invocation (line ~530). RQFROM-4 requires explicit `--resume`
for `--from-stage` to work; without it, the runner must refuse. S6 tested the DSFSTG-1
"leaf stage" path, which requires `--resume` to be present (S5 was updated earlier for
the same reason; S6 was missed). The state file already has `intake=complete` and the
artifact on the state branch; adding `--resume` causes the runner to enter resume mode
and the from-stage preflight to rehydrate intake before dispatching build.

Also fixed build-tests finding 1 answer: done — updated S6 to `--resume --from-stage build`.

## What is in each test file

### tests/unit/hydrate-stage-test.sh
- DSDLGT-1 ✓: overrides `_artifact_persist_put_back` with sentinel-writing function, runs `hydrate_run`, asserts sentinel was written

### tests/integration/resume-rehydrate-test.sh
- DSRHYD-1 ✓: artifacts restored byte-identical before dispatch loop (3 entry paths)
- DSRHYD-2 ✓: missing primary artifact → exit 1 before any stage.start
- DSSKIP-1 ✓: stage marked complete with artifact present → no stage.start in dispatch loop
- DSDSPK-1 ✓: interrupted stage k emits stage.start on resume (cycle and leaf branches)
- DSAMDR-1 ✓: ADR-006 step 3.6 amended, naming enforcing tests
- DSAMDR-2 ✓: ADR-050 §6 boundary note amended, naming ADR-006 and enforcing tests
- DSFRSH-1 ✓: fresh run (--no-resume) dispatches all stages from stage 1, no skip events
- DSFRSH-2 ✓: new run with prior artifacts → all stages dispatched, no stage.skip

### tests/integration/from-stage-rehydrate-test.sh
- DSFSTG-1 ✓: --from-stage <s> rehydrates prior stages and dispatches <s> first (S3, S5, S6)
  - S6 updated: now uses `--resume --from-stage build` (round 70 fix)
- DSFSTG-2 ✓: missing artifact → exit 1 with "has no restorable primary artifact" on stderr
- DSFSTG-3 ✓: combined --resume --from-stage; stages after <s> dispatched despite being complete (S10)
- DSFSTG-4 ✓: --from-stage without --resume exits 1 with "only valid with --resume"
  - S11: flat ZBUILD_STATE_FILE path, status=interrupted (auto-resume conditions met)
  - S12: latest-symlink path, ZBUILD_STATE_FILE/DIR unset via env -u, status=interrupted

### tests/integration/resume-loop-state-test.sh
- DSITER-1 ✓: cycle orchestrator starts at current_iter=2 on resume (not iter=1)
  - Also covers fresh run (no _ZBUILD_RESUME_ACTIVE) and nested-loop re-entry clauses
- DSCMBR-1 ✓: within interrupted iteration, build (complete) skipped; test (aborted) dispatched
  - Covers both iter=2 and iter=1 interrupted scenarios

### tests/integration/resume-entry-points-test.sh
- DSENTR-1 ✓: all three entry paths (--resume, auto-resume, zbuild pipeline resume) restore artifacts before dispatch
- DSENTR-2 ✓: auto-resume via latest symlink (ZBUILD_STATE_FILE/DIR unset via env -u) → pipeline.resume emitted, artifacts restored

### tests/integration/pipeline-resume-test.sh (not a SPEC test file, verified)
- Pre-writes intake artifact before --resume run (DSRHYD-2 compatibility) ✓
- --from-stage without --resume section uses status:"in_progress" with $now timestamp
  (auto-resume condition for RQFROM-4) — SAME AS BASE CODE
- This test FAILS on the branch because the branch has a code regression:
  the `--from-stage` guard in runner.sh was narrowed to `interrupted` only,
  so `in_progress` auto-resume fires first and the guard never fires.
  The test is CORRECT — it was identical to base code and passes on base code.
  Fixing the regression requires a code change to core/pipeline/runner.sh.

## Why pipeline-resume-test.sh still fails (implementation bug, not test bug)

Base code (runner.sh near line 1737): `if [[ -n "$from_stage" ]] && ! $resume_mode; then`
  — guard fires when `from_stage` is set AND `resume_mode` is still false (before any
    auto-resume processing). Works for ALL states (in_progress, interrupted, etc.).

Branch code: guard was narrowed to `if [[ "$_fsg_status" == "interrupted" ]]; then`
  or placed after auto-resume processing where `resume_mode` is already `true`.

Result: pipeline-resume-test.sh (which uses `in_progress` state) fails on branch code.
Fixing this requires restoring the guard to its pre-auto-resume position in runner.sh.
This is NOT in test-author scope.

## Findings answered (round 70)

### build-tests finding 1 (opened by build)
Done. S6 in `from-stage-rehydrate-test.sh` updated to use `--resume --from-stage build`.
The state file already has `intake=complete` with artifact on the state branch; adding
`--resume` causes the runner to enter resume mode and the from-stage preflight to
rehydrate intake before dispatching build. RQFROM-4 requires explicit `--resume` for
`--from-stage`; S6's DSFSTG-1 "leaf stage" path was testing that `--from-stage build`
dispatches build correctly, which requires `--resume` to be present.

### issue-acceptance finding 1 (opened by issue-acceptance)
Not mine. The pipeline-resume-test.sh test at "--from-stage without --resume exits 1"
correctly asserts RQFROM-4 (using `in_progress` state with recent timestamp, same as
base code). The test passes on base code and fails on branch code — that is the
definition of a code regression in core/pipeline/runner.sh. The test is correct;
fixing the guard's position in runner.sh is outside test-author scope.

### lens-correctness-code finding 2 (opened by review_lenses)
Wrong. DSCMBR-1's GIVEN explicitly states "persisted state records test as aborted."
Using `stage_statuses.test = "aborted"` is exactly right for the stated scenario.
The "all complete" pre-scan path (where `test` has status `complete` from an earlier
iteration) is not stated in any requirement or SPEC in this contract and is outside
the issue's acceptance boundary.

### lens-correctness-design finding 1 (opened by review_lenses)
Not mine. This is about the interaction of `skip_until_stage` and `resume_mode` inside
`core/pipeline/runner.sh`. My DSFSTG-3 test (S10 in from-stage-rehydrate-test.sh)
correctly asserts the observable requirement: stage.start (or cycle.start) is emitted
for each stage after `<s>` and no stage.skip events fire for stages after `<s>`.
Fixing the implementation guard in runner.sh is outside test-author scope.
