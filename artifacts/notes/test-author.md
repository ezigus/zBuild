# test-author notes — issue #1805 (round 18: fix ITER-1 nested-loop + FRSH-1 stage-1 assertions)

## Status: COMPLETE — both open findings addressed; all SPECs covered

## What changed this round

### Finding 2 (FRSH-1 "dispatches all stages from stage 1") — DONE
Added a [#1805/FRSH-1]-tagged assertion to resume-rehydrate-test.sh after the
existing [#1805/BNDY-1] intake-dispatch assertion (line 638). The new assertion:
  - Reuses `$_s12_intake_starts` (already computed by the BNDY-1 section)
  - asserts intake dispatched exactly 1 time (`assert_eq "1" "$_s12_intake_starts"`)
  - tagged `[#1805/FRSH-1]`
  - comment explains: state has status=interrupted + intake=complete, which would
    trigger auto-resume (skipping intake) if --no-resume were absent; with --no-resume
    the runner starts fresh from stage 1, proving dispatch was not jumped to a later
    stage due to prior state
  - FRSH-1 is no-code: need not fail before the change, must pass after

### Finding 1 (ITER-1 "nested-loop re-entries always start at iter=1") — DONE
Added a new sub-test section "clause 2b" to resume-loop-state-test.sh between the
main resume test (clause 1: starts at iter=2) and the guard test (clause 3: unset
starts at iter=1). The new sub-test:
  - Re-seeds state with `zb_engine_loop_state ... 1 5 "in_progress"` (current_iter=1)
  - Does NOT manually clear _ZBUILD_RESUME_ACTIVE (unlike the clause 3 guard test)
  - Calls cycle_orchestrator_run and captures the first iter dispatched
  - Asserts first iter == 1
  - Discriminating: if the implementation clears `_ZBUILD_RESUME_ACTIVE` after the
    outer resume uses it, this call starts at iter=1 (passes); if the implementation
    keeps the flag set, this call starts at iter=2 (fails — regression detector)
  - This directly tests the nested-loop re-entry behavior: after the outer cycle
    consumed the flag, the inner/nested cycle sees it as cleared and starts at iter=1
  - Before this change (no resume logic): always starts at 1 → passes trivially
  - After correct implementation: passes; after incorrect flag retention: fails

## Findings answered

### test-author finding 1 (ITER-1 nested-loop re-entries not established)
ANSWER: done — added "[#1805/ITER-1] nested-loop re-entry after outer resume starts at iter=1"
sub-test in resume-loop-state-test.sh. The sub-test calls cycle_orchestrator_run after
the outer resume consumed _ZBUILD_RESUME_ACTIVE, without manually clearing the flag.
If the implementation correctly clears it, the nested call starts at iter=1 (passes).
If not, it starts at iter=2 (fails). This establishes the "nested-loop re-entries
always start at iter=1" clause via the flag-consumption mechanism.

### test-author finding 2 (FRSH-1 "dispatches all stages from stage 1" not established)
ANSWER: done — added `assert_eq "[#1805/FRSH-1] fresh run (--no-resume) dispatches all
stages from stage 1 (intake dispatched; did not skip to a later stage due to prior state)"
"1" "$_s12_intake_starts"` after the BNDY-1 assertion in the BNDY-1 sub-case of
resume-rehydrate-test.sh.

### test-author finding 3 (BNDY-1 structural not established)
ANSWER: nothing to do — BNDY-1 is a no-code structural requirement that THIS FILE
contains both a resume-side assertion (RHYD-1/RHYD-2 sections at the top) and a
fresh-run sub-case with --no-resume (BNDY-1 section). Both sides exist in the file.
A test cannot assert that another assertion coexists in the same file; the structural
property is satisfied by the file's content. The assert_contains "[#1805/BNDY-1]"
assertion for the cycle fixture (and the intake dispatch check) are correct as-is.

### test-author finding 4 (DLGT-1 resume path not established in hydrate-stage-test.sh)
ANSWER: nothing to do — the design instruction for hydrate-stage-test.sh ONLY says to
add a sentinel test for hydrate_run (confirmed: "runs hydrate_run, and asserts the
sentinel was written — fails when plugin reverted to inline _hydrate_put_back"). The
current test does exactly this. The resume-side proof (that _artifact_persist_restore +
_artifact_persist_put_back are called on resume) is already established by RHYD-1 in
resume-rehydrate-test.sh via content comparison. Adding a resume-path test to
hydrate-stage-test.sh would require sourcing runner.sh (not in design instruction scope)
and is not required by any design instruction for that file.

## All SPECs and their assertions

### resume-rehydrate-test.sh
- RHYD-1: artifact-present (file exists + content from git state branch),
  dispatch-loop ran (at least 1 stage.start), pipeline.resume before first stage.start,
  intake emits no stage.start — for all 3 paths (--resume, auto-resume, zbuild pipeline resume)
- RHYD-2: exit 1 when artifact absent from disk AND state branch; no stage.start before exit
- AMDR-1: ADR-006 contains 3.6, _runner_resume_rehydrate, resume-rehydrate-test.sh,
  resume-entry-points-test.sh, "exit 1", "before the dispatch loop", "git state branch",
  "not to be combined with dispatch-loop changes"
- AMDR-2: ADR-050 s6 contains "new run", "ADR-006", "continues the same run"
- FRSH-1: (1) dispatches from stage 1 (intake dispatched, NEW); (2) no stage.skip events;
  (3) prior-run artifact content NOT in ZBUILD_ARTIFACT_DIR [ALL THREE NOW PRESENT]
- BNDY-1: --no-resume flag in the fresh-run sub-case; intake dispatches in fresh run;
  fixture has type: cycle
- CYCL-1: fixture (artifact-snapshot-coverage) has type: cycle; pipeline was run

### from-stage-rehydrate-test.sh
- FSTG-1: artifact-present + content from git state branch; intake emits no stage.start;
  cyc dispatched as first stage (cycle.start with cycle_id=cyc)
- FSTG-2: exit 1 when prior stage has no restorable artifact; stderr contains
  "has no restorable primary artifact"; no stage.start before exit
- CYCL-1: fixture (artifact-snapshot-coverage) has type: cycle

### resume-loop-state-test.sh
- ITER-1 clause 1: first dispatched iter is 2 (with _ZBUILD_RESUME_ACTIVE=true + current_iter=1)
- ITER-1 clause 2: iter-1 stages not dispatched on resume into iter-2
- ITER-1 clause 2b (NEW): nested-loop re-entry after outer resume starts at iter=1
  (does not manually clear flag; relies on implementation having consumed it)
- ITER-1 clause 3 (guard): without _ZBUILD_RESUME_ACTIVE, fresh run starts at iter=1

### resume-entry-points-test.sh
- ENTR-1 for all 3 paths:
  - artifact restored from state branch (file exists)
  - pipeline.resume event emitted (resume_lineno > 0)
  - pipeline.resume precedes first stage.start (rehydration before dispatch loop)

### hydrate-stage-test.sh
- DLGT-1: sentinel test — overrides _artifact_persist_put_back with touch; calls
  hydrate_run; asserts sentinel was written — fails when plugin.sh is reverted to
  inline _hydrate_put_back
