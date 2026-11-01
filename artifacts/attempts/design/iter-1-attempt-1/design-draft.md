# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

On any resume path — `--resume` flag, auto-resume on detecting `status=interrupted`, or
`zbuild pipeline resume --run-id X` — the runner must restore completed stages' artifacts from
the git state branch before the dispatch loop, using the same extraction mechanism the hydrate
plugin uses. After that restoration, a stage marked `complete` whose primary artifact is still
absent must cause the resume to refuse with exit 1 (fail closed), not warn-and-skip.

For `--from-stage`, a preflight must verify that every stage before the named target has a
restorable artifact; if any stage has no output anywhere, the runner refuses before dispatching
anything.

The cycle orchestrator must read the persisted `cycle_iterations[X].current_iter` at resume
entry and start the iteration loop from that value, not reset to 1.

Because the runner cannot source plugin implementations (ADR-001), the copy operation is
extracted from `_hydrate_put_back` in the hydrate plugin into a new `_artifact_persist_put_back`
function in `core/state/artifact-persist.sh`. Both the hydrate plugin and the runner call it
from that shared location (R-7: "same path").

ADR-006 is amended to add step 3.5 to the resume sequence. ADR-050 §6 is amended to draw the
explicit line between resume (same run, governed by ADR-006) and new-run reuse (governed by
ADR-050 §6, which forbids skipping a stage on the basis of prior output).

```scope
core/pipeline/runner.sh
core/state/artifact-persist.sh
plugins/tool/hydrate/plugin.sh
core/pipeline/cycle-orchestrator.sh
docs/adr/ADR-006-resume-contract.md
docs/adr/ADR-050-prior-work-reuse-contract.md
tests/integration/resume-rehydrate-test.sh           [new]
tests/integration/from-stage-rehydrate-test.sh        [new]
tests/integration/resume-loop-state-test.sh           [new]
tests/integration/resume-entry-points-test.sh         [new]
tests/integration/pipeline-resume-test.sh             [update]
tests/integration/resume-after-sigint-test.sh         [update]
tests/unit/hydrate-stage-test.sh                      [update]
```

```steps
1.  [ADR] Amend docs/adr/ADR-006-resume-contract.md: insert step 3.5 in the resume sequence
    between "load state" and "continue from last in_progress stage":
      "3.5 Rehydrate completed-stage artifacts. The runner calls _artifact_persist_restore to
      extract the run's state branch into a staging directory, then _artifact_persist_put_back
      to copy no-clobber into ZBUILD_ARTIFACT_DIR. A stage with stage_statuses[s]='complete'
      whose primary artifact remains absent after this step causes the resume to exit 1."

2.  [ADR] Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add a boundary note after
    the existing "never skip a stage on basis of prior output" rule:
      "This invariant applies to new runs of the same issue. A resume continues the same run
      and is governed by ADR-006; the artifact restoration in step 3.5 of the resume sequence
      is not a stage skip — the stage already completed within this run."

3.  [code] In core/state/artifact-persist.sh: add _artifact_persist_put_back <from_dir> <to_dir>
    that copies files no-clobber from <from_dir> to <to_dir>, skipping anything under a
    stage-io/ subdirectory. This is the logic currently inlined in _hydrate_put_back in the
    hydrate plugin; the function body is identical. No behavioral change to the hydrate path.

4.  [code] In plugins/tool/hydrate/plugin.sh: replace the inline _hydrate_put_back call
    (including the function definition) with a call to _artifact_persist_put_back. Hydrate
    already sources core/state/artifact-persist.sh, so no new source line is needed.

5.  [update] Update tests/unit/hydrate-stage-test.sh: for any SPEC that references or calls
    _hydrate_put_back directly, redirect to _artifact_persist_put_back. Run the unit test and
    confirm it is green before proceeding.

6.  [test-RED] Write tests/integration/resume-rehydrate-test.sh (SPEC-1 + SPEC-2):
      - SPEC-1 case: create a git state branch with a "complete" stage's artifact committed,
        set ZBUILD_ARTIFACT_DIR to an empty temp dir, run runner --resume; assert the artifact
        is present in ZBUILD_ARTIFACT_DIR before the first non-complete stage.start event.
      - SPEC-2 case: create state with stage_statuses["intake"]="complete" but no artifact on
        disk or the state branch; run runner --resume; assert exit 1 and zero stage.start events.
    Run — confirm both cases FAIL (SPEC-1 shows artifact absent; SPEC-2 shows exit 0).

7.  [code] In core/pipeline/runner.sh: add _runner_resume_rehydrate function that:
      (a) calls _artifact_persist_restore to extract state branch artifacts to a temp staging dir
      (b) calls _artifact_persist_put_back staging_dir ZBUILD_ARTIFACT_DIR
    Source core/state/artifact-persist.sh at the runner's source block if not already present.
    Call _runner_resume_rehydrate immediately after the abort sentinel disarm at the resume entry
    point (~line 2783), for all three resume paths (--resume flag, auto-resume, and the path
    reached via scripts/zbuild pipeline resume --run-id).
    Change the stale-artifact branch in the dispatch loop (runner.sh:3727-3751): after
    rehydration has already run, if the primary artifact is still absent, exit 1 with a message
    that names the stage; remove the warn-and-continue path.

8.  [test-GREEN] Run tests/integration/resume-rehydrate-test.sh — confirm SPEC-1 and SPEC-2
    both pass.

9.  [test-RED] Write tests/integration/from-stage-rehydrate-test.sh (SPEC-3 + SPEC-4):
      - SPEC-3 case: state branch holds artifact for "intake" (pre-target stage); run runner
        --resume --from-stage build; assert zero stage.start for intake, one for build, and
        intake's artifact present in ZBUILD_ARTIFACT_DIR.
      - SPEC-4 case: state branch has no artifact for intake; run runner --resume --from-stage
        build; assert exit 1, zero stage.start events, and stderr names "intake".
    Run — confirm both cases FAIL (SPEC-3 shows pre-target artifact absent or intake dispatched;
    SPEC-4 shows exit 0).

10. [code] In core/pipeline/runner.sh: add _runner_from_stage_preflight <target_stage> function
    that runs before the dispatch loop when --from-stage is set:
      (a) enumerates all stages in template order that precede <target_stage>
      (b) calls _artifact_persist_restore (state branch → staging dir) once
      (c) calls _artifact_persist_put_back staging_dir ZBUILD_ARTIFACT_DIR
      (d) for each pre-target stage, resolves its primary artifact path; if any is absent,
          exits 1 with a message naming the missing stage and does not start the dispatch loop
    Call _runner_from_stage_preflight at the --from-stage validation site, after the existing
    "is not a known stage" check and before the dispatch loop.

11. [test-GREEN] Run tests/integration/from-stage-rehydrate-test.sh — confirm SPEC-3 and SPEC-4
    both pass.

12. [test-RED] Write tests/integration/resume-loop-state-test.sh (SPEC-7):
      - Create state with a cycle group where cycle_iterations[build-test].current_iter=2 and
        iter-1 stages are all "complete"; run runner --resume; assert no stage.start events for
        any iter-1 stage and at least one stage.start for iter-2.
    Run — confirm FAIL (runner dispatches iter-1 stages).

13. [code] In core/pipeline/cycle-orchestrator.sh: in _cycle_orchestrator_run_body, before the
    for loop, read cycle_iterations[<cycle_id>].current_iter from persisted state via
    get_state_field (defaulting to 1 if absent); use that value as the loop's starting index.
    Do not reset the counter. The existing `//=` guard in _cycle_state_init already preserves
    the field across calls.

14. [test-GREEN] Run tests/integration/resume-loop-state-test.sh — confirm SPEC-7 passes.

15. [test-RED] Write tests/integration/resume-entry-points-test.sh (SPEC-9):
      - Three sub-cases, one per entry path: --resume flag, auto-resume (state=interrupted and
        no --resume flag), and zbuild pipeline resume --run-id X CLI. In each case, put an
        artifact on the state branch and assert it appears in ZBUILD_ARTIFACT_DIR before the
        first non-complete stage dispatches.
    Run — confirm all three FAIL (artifact absent from ZBUILD_ARTIFACT_DIR in each path).

16. [code] Verify that all three resume paths in runner.sh and scripts/zbuild reach
    _runner_resume_rehydrate before the dispatch loop:
      (a) --resume flag: already handled by step 7
      (b) auto-resume (runner detects status=interrupted on startup): trace the auto-resume
          code path in runner.sh and add the rehydrate call there if it is a separate branch
      (c) zbuild pipeline resume --run-id X: scripts/zbuild:595-654 calls runner.sh --resume,
          so path (a) already covers it — confirm by reading scripts/zbuild

17. [test-GREEN] Run tests/integration/resume-entry-points-test.sh — confirm all three sub-cases
    pass.

18. [update] Update tests/integration/pipeline-resume-test.sh integration section (~line 229):
    add a pre-write of $INT_STATE_DIR/../artifacts/intake-result.json (or the path the runner
    resolves as the primary artifact for the intake stage) immediately before the --resume run.
    Confirm the test exits 0 and the existing assertions still pass.

19. [update] Update tests/integration/resume-after-sigint-test.sh: verify whether the Phase 1
    mock_plugin_factory "intake" stub writes a primary artifact as declared in its manifest.
    If it does not, replace mock_plugin_factory "intake" with an explicit stub that writes
    intake-result.json before returning 0, so Phase 2 --resume finds it after rehydration.
    Confirm P2.T1 (rc=0) still passes.

20. [final] Run npm test — confirm the full suite is green.
```

```acceptance
SPEC-1 [code]: On resume (any entry path), before the dispatch loop, the runner calls
  _artifact_persist_restore + _artifact_persist_put_back and places completed-stage artifacts
  from the git state branch into the live artifact directory. Evidence: runner exits 0 and the
  "complete" stage's artifact is present in ZBUILD_ARTIFACT_DIR when rehydration supplies it
  from the state branch; no stage.start event for the complete stage.
  covers: R-1 R-2 R-7
  WIRING: core/pipeline/runner.sh — _runner_resume_rehydrate called at resume entry (~line 2783)
  TESTFILES: tests/integration/resume-rehydrate-test.sh

SPEC-2 [code]: A stage with stage_statuses[s]="complete" whose primary artifact is absent from
  both disk and the git state branch causes the resume to exit 1 (fail closed). No stage.start
  event is emitted for any stage. Evidence: runner exits 1 when ZBUILD_ARTIFACT_DIR is empty and
  the state branch holds no artifact for the complete stage.
  covers: R-2 R-8
  WIRING: core/pipeline/runner.sh — stale-artifact branch changed from warn+continue to exit 1
  TESTFILES: tests/integration/resume-rehydrate-test.sh

SPEC-3 [code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore
  + _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s>
  as the first stage, and emits no stage.start event for any earlier stage. Evidence: exactly
  one stage.start event (for <s>) in events.jsonl; pre-<s> artifact present in ZBUILD_ARTIFACT_DIR
  after the run.
  covers: R-4 R-10
  WIRING: core/pipeline/runner.sh — _runner_from_stage_preflight called before dispatch loop
  TESTFILES: tests/integration/from-stage-rehydrate-test.sh

SPEC-4 [code]: --from-stage <s> when a stage before <s> has no artifact on disk and no artifact
  on the git state branch exits 1 with a message that names the missing stage, before dispatching
  anything. Evidence: exit 1, stderr contains the missing stage name, zero stage.start events.
  covers: R-11
  WIRING: core/pipeline/runner.sh — _runner_from_stage_preflight, exit 1 path
  TESTFILES: tests/integration/from-stage-rehydrate-test.sh

SPEC-5 [no-code]: ADR-006-resume-contract.md amended to include step 3.5 in the resume sequence:
  "Before the dispatch loop, the runner restores completed-stage artifacts from the git state
  branch using the same mechanism as the hydrate plugin. A stage marked complete whose primary
  artifact remains absent after this step causes the resume to exit 1."
  covers: R-5

SPEC-6 [no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: "This
  invariant (never skip a stage on basis of prior output) applies to new runs. A resume continues
  the same run and is governed by ADR-006; the artifact restoration in ADR-006 step 3.5 is not a
  stage skip."
  covers: R-6

SPEC-7 [code]: Cycle orchestrator reads cycle_iterations[<cycle_id>].current_iter from persisted
  state at resume entry and starts the iteration loop from that value (not from 1). Stages with
  stage_statuses="complete" within the interrupted iteration are not re-dispatched. Evidence: on
  resume with current_iter=2 in persisted state, no stage.start event for iter-1 stages; at least
  one stage.start for an iter-2 stage.
  covers: R-9
  WIRING: core/pipeline/cycle-orchestrator.sh — _cycle_orchestrator_run_body reads persisted iter
  TESTFILES: tests/integration/resume-loop-state-test.sh

SPEC-8 [done]: The run picks up at the first non-complete stage on resume.
  Evidence: core/pipeline/runner.sh:3724-3751 — the existing complete-stage skip loop already
  exits the dispatch iteration for any stage with stage_statuses[s]="complete".
  covers: R-3

SPEC-9 [code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting
  status=interrupted, zbuild pipeline resume --run-id X CLI) invoke _runner_resume_rehydrate
  before the dispatch loop. Evidence: in each path, a state-branch artifact appears in
  ZBUILD_ARTIFACT_DIR before the first non-complete stage dispatches.
  covers: R-12
  WIRING: core/pipeline/runner.sh — _runner_resume_rehydrate; scripts/zbuild pipeline-resume path
  calls runner.sh --resume, so it is covered by the runner-side rehydration call
  TESTFILES: tests/integration/resume-entry-points-test.sh

SPEC-10 [done]: A run with no prior state file proceeds as a fresh start with no rehydration.
  Evidence: core/state/resume.sh:246-249 — get_resume_recommendation returns fresh_start when
  the state file is absent; the runner's resume mode is never activated.
  covers: R-13

SPEC-11 [done]: A new run of the same issue never skips a stage because of an earlier run's output.
  Evidence: tests/unit/prior-work-reuse-contract-test.sh C3 asserts that a new-run dispatcher
  does not observe prior artifacts.
  covers: R-14
```

```supersedes
tests/integration/pipeline-resume-test.sh [SPEC-2]: the integration section (~line 229) writes
  stage_statuses["intake"]="complete" but writes no intake-result.json artifact. Currently the
  runner warns and skips (exit 0). After SPEC-2, a missing artifact post-rehydration causes
  exit 1, breaking the "integration: --resume exits 0" assertion. Fix (step 18): pre-write the
  intake primary artifact to ZBUILD_ARTIFACT_DIR before the --resume run.

tests/integration/resume-after-sigint-test.sh [SPEC-2]: Phase 1 uses mock_plugin_factory
  "intake" which may not write a primary artifact as declared in its manifest. If it does not,
  then after Phase 1 intake is "complete" on disk with no artifact. After SPEC-2, Phase 2
  --resume fails closed (exit 1), breaking P2.T1 (rc=0). Fix (step 19): if Phase 1 stub does not
  write intake-result.json, replace it with a stub that does before returning 0.
```
