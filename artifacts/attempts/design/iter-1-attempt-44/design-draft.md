# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume on restart, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1. Additionally, within the first resumed iteration, `_cycle_dispatch` must skip cycle member stages already marked complete in persisted state and explicitly emit stage.start for the interrupted (non-complete) member, so the first dispatched cycle member is the one that was actually interrupted.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed** — `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed** — exit 1 path at runner.sh:3920 (comment: "ADR-006 §3.6 (#1805): fail closed").
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed** — `_runner_from_stage_preflight` at runner.sh:1733.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, breaking nested loops. **Fixed** — cycle-orchestrator.sh:2337 wraps the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then`; flag is consumed immediately at line 2343 (`_ZBUILD_RESUME_ACTIVE=false`, comment: "Consume the flag: nested cycles and subsequent re-entries start at 1"); fresh/nested-loop re-entries take the else branch setting `_start_iter=1`.
- Gap 5 — dispatch-unit loop (cycle:* arm, stage:* arm) lacked skip-on-complete guard for resume mode; only the legacy linear loop had one. **Fixed** — guards at runner.sh:3442 (cycle:*) and runner.sh:3724-3760 (stage:*), both conditioned on `$resume_mode`; added by this branch.
- Gap 6 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**
- Gap 7 — An unconditional `_cd_iter > 0` guard was added to `_cycle_dispatch` (runner.sh:3213) to emit `stage.start` for all cycle member dispatches. This is WRONG: `_cd_iter` starts at 1 and only increases, so the guard fires on every dispatch in every run (fresh and resume). Issue-acceptance finding 2 confirms this changes fresh-run event sequences and breaks `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden`, violating RQGUAR-1. Stage.start for the interrupted cycle member during resume does NOT require an unconditional guard — it must be emitted by the DSCMBR-1 `resume_first_iter=true` path: when `resume_first_iter=true` and the cycle member is not marked complete (the interrupted member), `_cycle_dispatch` explicitly emits `stage.start` for that member before dispatching. For fresh runs and later resumed iterations (`resume_first_iter=false` or not set), `_cycle_dispatch` preserves pre-branch behavior: no stage.start emission for cycle members through this code path. If the branch added the `_cd_iter > 0` guard, it must be removed. DSCYCM-1[done] is removed — the evidence text was added by this branch, making [done] untenable.
- Gap 8 — runner.sh auto-resume check (line 2174) tests `[[ -f "$state_file" ]]` where `state_file = $state_dir/pipeline-state.json` (the flat default root path). But the per-run layout (ADR-059 §1) stores state at `runs/<run_id>/pipeline-state.json`, not at the root. The `latest` symlink at `$(zbuild_layout_state_root)/latest` points to the most-recent per-run dir and is already used by `_find_state_file` in `scripts/zbuild`, but runner.sh's auto-resume check never consults it. Result: without ZBUILD_STATE_FILE set, auto-resume never fires for any per-run default layout. All existing auto-resume tests mask this gap by setting ZBUILD_STATE_FILE explicitly. **NOT YET FIXED** — extend the auto-resume elif to check `$state_dir/latest/pipeline-state.json` when the flat path does not exist, and update state_dir/state_file to the resolved per-run path when `auto_resume` fires (step 7b).
- Gap 9 — Within the first resumed iteration (iter k), member stages already marked complete must be skipped so the first dispatched member is the interrupted stage. DSSKIP-1's dispatch-unit skip guard applies to top-level `_TPL_DISPATCH_UNITS` entries only; `_cycle_dispatch` is called from inside the cycle orchestrator and has no equivalent guard. **NOT YET FIXED** — the cycle orchestrator must signal to `_cycle_dispatch` whether it is dispatching the first resumed iteration, and `_cycle_dispatch` must skip members already marked complete and explicitly emit stage.start for the non-complete (interrupted) member (step for DSCMBR-1).
- Gap 10 — `pipeline.skip_to_stage` emission in combined resume+from-stage mode. runner.sh:2963 emits the event whenever `--from-stage` is active, including when `--resume` is also active. RQFROM-2 says the event must not be FOLLOWED BY running an earlier stage — that constraint is met because the rehydration path and dispatch-loop skip guards prevent earlier-stage dispatch in both pure from-stage and resume+from-stage modes. The event's emission in combined mode is therefore RQFROM-2-compliant; DSFSTG-1 makes this explicit via a Then clause. No code change is required for this gap — the existing behavior satisfies RQFROM-2.

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into `_artifact_persist_put_back <from> <to>` in `core/state/artifact-persist.sh`. Redirect hydrate's `hydrate_run` call site to the new function. At the resume entry point in runner.sh, export `_ZBUILD_RESUME_ACTIVE=true` (already at line 2862). In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi`; the flag is consumed immediately after reading (`_ZBUILD_RESUME_ACTIVE=false`) so nested cycles and subsequent re-entries always start at iter=1. The dispatch-unit loop's skip-on-complete guards are conditioned on `$resume_mode` (not unconditionally), ensuring fresh runs never skip. Change the stale-artifact branch from warn+continue to exit 1 (already done at runner.sh:3920). Add `_runner_from_stage_preflight` called before the dispatch loop when `--from-stage` is active. `_cycle_dispatch` must NOT add an unconditional stage.start guard keyed on `_cd_iter > 0`: since `_cd_iter` starts at 1 the guard fires for every dispatch in every run, changing fresh-run event sequences and breaking golden files (RQGUAR-1). Stage.start for the interrupted cycle member during resume flows from the DSCMBR-1 `resume_first_iter=true` path: when `resume_first_iter=true` and the member is not marked complete, `_cycle_dispatch` explicitly emits `stage.start` for that member's stage id then dispatches normally; when `resume_first_iter=false` (fresh runs and later resumed iterations), no stage.start is emitted for cycle members via this path, preserving pre-branch behavior and golden file event sequences. If the branch added a `_cd_iter > 0` unconditional guard, it must be reverted. In the auto-resume elif branch (runner.sh:2174), extend state discovery to check `$state_dir/latest/pipeline-state.json` when `$state_dir/pipeline-state.json` does not exist; when `auto_resume` recommendation fires via the `latest` path, update state_dir to the resolved per-run dir and state_file to `state_dir/pipeline-state.json` so artifact operations use the correct directory. In `_cycle_dispatch` (runner.sh:~3204) add a skip-on-complete guard controlled by a new `resume_first_iter` local flag: the cycle orchestrator sets this flag to `true` only for the first iteration dispatched during a resume (when `_start_iter > 1`); `_cycle_dispatch` with `resume_first_iter=true` checks the cycle member stage's persisted status and: (a) skips (no stage.start, no dispatch) any member already marked complete; (b) for the non-complete (interrupted) member: explicitly emits `stage.start` for that member's stage id, then dispatches normally; the flag is passed as an argument so it has no interaction with `_ZBUILD_RESUME_ACTIVE` (already consumed). Amend ADR-006 and ADR-050. All four test files required by RQTEST-1 (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, resume-loop-state-test.sh, resume-entry-points-test.sh) must include a cycle stage in their pipeline fixture, verified by an assert_contains tagged [#1805/DSCYCL-1] in each file.

```scope
core/pipeline/runner.sh
core/state/artifact-persist.sh
plugins/tool/hydrate/plugin.sh
core/pipeline/cycle-orchestrator.sh
docs/adr/ADR-006-resume-contract.md
docs/adr/ADR-050-prior-work-reuse-contract.md
tests/integration/resume-rehydrate-test.sh
tests/integration/from-stage-rehydrate-test.sh
tests/integration/resume-loop-state-test.sh
tests/integration/resume-entry-points-test.sh
tests/integration/pipeline-resume-test.sh
tests/integration/resume-after-sigint-test.sh
tests/unit/hydrate-stage-test.sh
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh
tests/integration/nested-loop-rounds-test.sh
tests/integration/nested-loop-rounds-build-test.sh
tests/integration/cycle-member-dispatch-events-test.sh
tests/golden/full-pipeline/event-sequence.golden
tests/golden/parity/event-sequence.golden
```

```steps
- Amend docs/adr/ADR-006-resume-contract.md: insert step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes) and add enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) inline | areas: docs/adr/ADR-006-resume-contract.md
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs); update §6's Enforced by entry to also cite resume-rehydrate-test.sh (DSFRSH-2 for the new-run side) and resume-entry-points-test.sh (DSENTR-1 for the resume side) alongside the existing resume-default-test.sh R5–R11 citation | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh (no-clobber copy skipping stage-io/); body identical to current _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh hydrate_run call site (line 162) to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: add [#1805/DSDLGT-1] section that overrides _artifact_persist_put_back with a sentinel-writing function, runs hydrate_run, and asserts the sentinel was written — fails when plugin reverted to inline _hydrate_put_back | areas: tests/unit/hydrate-stage-test.sh
- Confirm _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: the `_ZBUILD_RESUME_ACTIVE` guard (wrapping `_persisted_iter` read; consuming flag immediately with `_ZBUILD_RESUME_ACTIVE=false`; else branch sets `_start_iter=1`) is already in place — verify it is present and correct | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, confirm `export _ZBUILD_RESUME_ACTIVE=true` is present immediately after the _runner_resume_rehydrate call (runner.sh:2862); do NOT set it for fresh runs; remove any unconditional `_cd_iter > 0` stage.start guard from `_cycle_dispatch` if the branch added one — it was added in error (issue-acceptance finding 2, Gap 7); stage.start for the interrupted cycle member during resume flows from the DSCMBR-1 `resume_first_iter=true` path (see step below), not from an unconditional iter guard | areas: core/pipeline/runner.sh
- In runner.sh auto-resume elif branch (line 2174), extend state discovery: when `$state_dir/pipeline-state.json` does not exist and `$state_dir/latest` is a symlink to a directory containing `pipeline-state.json`, use `$state_dir/latest/pipeline-state.json` as the candidate state file; when `auto_resume` recommendation fires via this path, update state_dir to the resolved per-run directory (via readlink -f) and state_file to `$state_dir/pipeline-state.json`; ensures auto-resume works for the per-run default layout (ADR-059 §1) without requiring ZBUILD_STATE_FILE | areas: core/pipeline/runner.sh
- Update tests/integration/resume-entry-points-test.sh: (1) add [#1805/DSENTR-2] sub-case that sets ZBUILD_STATE_ROOT to a temp directory, creates `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with status=interrupted and intake=complete, creates a `$ZBUILD_STATE_ROOT/latest` symlink pointing to that dir, invokes the runner with ZBUILD_STATE_FILE and ZBUILD_STATE_DIR unset, and asserts: pipeline.resume event emitted (auto-resume fired), completed-stage artifacts restored, no stage.start for intake. CRITICAL: the sub-case must NOT set ZBUILD_STATE_FILE or ZBUILD_STATE_DIR in the test environment — these must be absent/unset so the auto-resume symlink guard `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` can fire; if ZBUILD_STATE_FILE is set the guard is false and the new code path is dead (issue-acceptance finding 1). (2) add [#1805/DSCYCL-1] assertion verifying the pipeline fixture used in this test file contains a stage of type: cycle | areas: tests/integration/resume-entry-points-test.sh
- Verify (and revert if changed by the branch) tests/golden/full-pipeline/event-sequence.golden and tests/golden/parity/event-sequence.golden: these files encode the pre-branch fresh-run event sequence; if the branch added stage.start events for cycle members in fresh runs (from the erroneous `_cd_iter > 0` guard), those additions must be reverted so the golden files match the restored behavior | areas: tests/golden/full-pipeline/event-sequence.golden, tests/golden/parity/event-sequence.golden
- Update tests/integration/cycle-member-dispatch-events-test.sh: (1) update iteration count assertions after the DSITER-1 fix in cycle-orchestrator.sh; (2) do NOT add stage.start count assertions for cycle members in fresh runs — the erroneous `_cd_iter > 0` guard is removed (issue-acceptance finding 2), so fresh-run cycle members must not emit extra stage.start events; if such assertions were added to this test, remove them; (3) also confirm cycle-inner-iter-resets-per-outer-iter-test.sh, nested-loop-rounds-test.sh, and nested-loop-rounds-build-test.sh pass after the cycle-orchestrator DSITER-1 guard fix | areas: tests/integration/cycle-member-dispatch-events-test.sh, tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh
- Update tests/integration/resume-loop-state-test.sh: (1) add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the cycle_orchestrator_run call so the [#1805/DSITER-1] assertion "first dispatched iter is 2" reaches the guard; (2) add [#1805/DSCMBR-1] sub-case with a fixture where iter 1 fully completed and iter 2 ran build (complete) then was interrupted before test; set up persisted state accordingly; invoke the runner with --resume; assert no stage.start event for "build" in iter 2 and a stage.start event for "test" in iter 2; (3) add [#1805/DSCYCL-1] assertion verifying the pipeline fixture used in this test file contains a stage of type: cycle | areas: tests/integration/resume-loop-state-test.sh
- In `_cycle_dispatch` (runner.sh:~3204) and the cycle orchestrator body (cycle-orchestrator.sh), add the skip-on-complete guard for the first resumed iteration: the cycle orchestrator passes `resume_first_iter=true` only when dispatching members of `_start_iter` during a resume (i.e., `_start_iter > 1` and current iter == `_start_iter`); `_cycle_dispatch` with `resume_first_iter=true`: (a) for members already marked complete in persisted state: skip — no stage.start, no dispatch; (b) for the non-complete (interrupted) member: explicitly emit `stage.start` for that member's stage id, then dispatch normally. For `resume_first_iter=false` or not set (fresh runs and later resumed iterations): no stage.start is emitted for cycle members through this code path (pre-branch behavior preserved, golden files intact) — this is the DSCMBR-1 fix (Gap 9) | areas: core/pipeline/runner.sh, core/pipeline/cycle-orchestrator.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix grep-c anti-pattern sites — replace with wc -l; (2) add --no-resume flag to the fresh-run sub-case; (3) remove any stale cycled-dispatch assert_gt block that expected stage.start for all cycle members in fresh runs (the `_cd_iter > 0` guard is removed); (4) retag the assert_contains type:cycle line to [#1805/DSCYCL-1]; (5) add [#1805/DSFRSH-1] assertion in the --no-resume sub-case verifying all stages dispatched from stage 1 with no stage.skip events emitted; (6) add [#1805/DSDSPK-1] assertion in the resume sub-case verifying the interrupted cycle member (the non-complete one) emits stage.start — this is provided by the DSCMBR-1 `resume_first_iter=true` path; (7) add [#1805/DSFRSH-2] assertion in a sub-case with prior run state present and no --resume flag, verifying no stages are skipped due to prior run output; (8) add [#1805/DSSKIP-1] assertion in the resume sub-case verifying no stage.start for a stage already marked complete whose artifact is present after rehydration | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: (1) fix DSFSTG-1 zero-count grep-c with wc -l; (2) retag assert_contains type:cycle to [#1805/DSCYCL-1]; (3) change DSFSTG-2 assert_contains to check for "has no restorable primary artifact" | areas: tests/integration/from-stage-rehydrate-test.sh
- Verify tests/integration/resume-entry-points-test.sh: three entry-path assertions tagged [#1805/DSENTR-1] | areas: tests/integration/resume-entry-points-test.sh
- Verify tests/integration/pipeline-resume-test.sh: intake's primary artifact pre-written to ZBUILD_ARTIFACT_DIR before the --resume run | areas: tests/integration/pipeline-resume-test.sh
- Verify tests/integration/resume-after-sigint-test.sh: mock_plugin_factory "intake" writes intake-result.json; runner snapshots it after Phase 1; resume rehydration restores it; P2.T1 (rc=0) still passes with DSRHYD-2 fail-closed in effect | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
DSRHYD-1[code]: On resume, before the dispatch loop, completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical to their state at interruption, and no stage.start event is emitted for them covers: RQRESU-1 RQRESU-2 RQRESU-4 RQHYDR-1
  Given: A run has been interrupted; stage k-1 is marked complete with its artifacts present in the git state branch; stage k was the interrupted stage
  When: The run is resumed via any of the three entry paths (--resume flag, auto-resume on status=interrupted, or zbuild pipeline resume --run-id)
  Then: The completed stage's artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical to their state at the time of interruption
  And: No stage.start event is emitted for the completed stage
DSRHYD-2[code]: A complete stage whose primary artifact cannot be rehydrated causes exit 1 before any stage.start event is emitted covers: RQRESU-2
  Given: A run is being resumed; a stage is marked complete in persisted state; its primary artifact is absent from both disk and the git state branch after rehydration attempt
  When: The runner processes that stage during resume rehydration
  Then: The runner exits 1
  And: No stage.start event has been emitted for any stage
DSFSTG-1[code]: --from-stage <s> rehydrates all stages before <s> and dispatches <s> as the first stage covers: RQFROM-1 RQFROM-2
  Given: A previous run completed stages before <s>; their artifacts are present in the git state branch; a new invocation uses --from-stage <s>
  When: The runner starts with --from-stage <s>
  Then: The artifacts from every stage before <s> appear in ZBUILD_ARTIFACT_DIR before the dispatch loop starts
  And: Stage <s> is dispatched as the first unit — when <s> is a cycle stage, a cycle.start event is emitted for <s> and stage.start is emitted for <s>'s first cycle member; when <s> is a leaf stage, a stage.start event is emitted for <s>; no corresponding dispatch event fires for any stage before <s>
  And: No stage.start event is emitted for any stage before <s>
  And: `pipeline.skip_to_stage` is emitted when `--from-stage` is active (whether or not `--resume` is also active); no stage before <s> is dispatched after that event — rehydration and dispatch-loop skip guards prevent it, satisfying RQFROM-2 in both pure from-stage and combined resume+from-stage modes
DSFSTG-2[code]: --from-stage <s> when a prior stage has no restorable artifact emits a diagnostic and exits 1 before any stage.start event covers: RQFROM-3
  Given: --from-stage <s> is active; at least one stage before <s> has no restorable primary artifact in the git state branch
  When: The runner performs the from-stage preflight check
  Then: The diagnostic phrase "has no restorable primary artifact" appears on stderr
  And: The runner exits 1 before any stage.start event is emitted
DSAMDR-1[no-code]: ADR-006-resume-contract.md amended with step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes); enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: RQADR-1
DSAMDR-2[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant "never skip a stage on prior output" applies to new runs; a resume continues the same run and is governed by ADR-006; and §6's Enforced by section updated to cite resume-rehydrate-test.sh (DSFRSH-2 for the new-run side) and resume-entry-points-test.sh (DSENTR-1 for the resume side) covers: RQADR-2
DSITER-1[code]: Cycle orchestrator reads current_iter from persisted state on resume and starts the iteration loop from that value; fresh runs and nested-loop re-entries always start at iter=1 covers: RQLOOP-1
  Given: A run is being resumed; persisted state records cycle_iterations[CYCLE_ID].current_iter=2 (iter 1 completed before interruption); _ZBUILD_RESUME_ACTIVE=true is exported
  When: The cycle orchestrator's run body executes
  Then: The iteration loop starts at iter 2, not iter 1
  And: No stage.start event is emitted for any iter-1 stage
  And: When _ZBUILD_RESUME_ACTIVE is false or unset (fresh run or nested-loop re-entry), the loop starts at iter=1
DSCMBR-1[code]: On resume, within the interrupted iteration, cycle member stages already marked complete in persisted state are skipped; the first dispatched cycle member is the interrupted stage covers: RQLOOP-1
  Given: A run is being resumed; in the interrupted iteration (iter k), member stage "build" completed and member stage "test" was interrupted before completing; persisted state records build as complete and test as in-progress within iter k
  When: The cycle orchestrator dispatches members of iter k
  Then: No stage.start event is emitted for "build" (already complete in iter k)
  And: stage.start is emitted for "test" (the interrupted member of iter k)
DSSKIP-1[code]: On resume, the dispatch-unit loop skips a stage marked complete whose primary artifact is present after rehydration, emitting no stage.start for that stage covers: RQRESU-3 RQRESU-4 RQDISP-1
  Given: A run is being resumed; a stage is marked complete in persisted state and its primary artifact is present in ZBUILD_ARTIFACT_DIR after rehydration
  When: The dispatch-unit loop reaches that stage
  Then: No stage.start event is emitted for that stage
DSDSPK-1[code]: On resume, stage k (the interrupted stage) is dispatched and emits stage.start covers: RQRESU-3 RQRESU-4
  Given: A run with stages 1…N was interrupted during stage k; stages 1…k-1 are marked complete with their artifacts present in ZBUILD_ARTIFACT_DIR after rehydration
  When: The dispatch loop reaches stage k during resume
  Then: Stage k is dispatched — when k is a cycle stage, a cycle.start event is emitted for k and stage.start is emitted for k's first non-complete cycle member; when k is a leaf stage, a stage.start event is emitted for k
DSENTR-1[code]: All three resume entry paths (--resume flag, auto-resume on status=interrupted, zbuild pipeline resume --run-id) restore completed-stage artifacts before the dispatch loop covers: RQPATH-1
  Given: A run has been interrupted and its state is persisted in runs/<run_id>/
  When: The run is resumed via any of the three entry paths in turn
  Then: Completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR before any stage.start event is emitted, for each of the three entry paths independently
  And: No stage.start event is emitted for any stage marked complete in the interrupted run's state
DSENTR-2[code]: On auto-resume, when no ZBUILD_STATE_FILE is set and the most recent run's state is under the per-run path `runs/<run_id>/`, the runner finds it via the `latest` symlink and enters resume_mode covers: RQPATH-1
  Given: A previous run stored state at `$state_root/runs/<run_id>/pipeline-state.json` with status=interrupted; `$state_root/latest` symlinks to that per-run dir; ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset in the test environment
  When: The runner is invoked with no --resume flag and ZBUILD_STATE_FILE not set
  Then: resume_mode is set to true (pipeline.resume event is emitted)
  And: Completed-stage artifacts are restored from the per-run state directory before any stage.start event
DSFRSH-1[no-code]: A fresh run dispatches all stages from stage 1 with no stage skipped due to prior state and no prior-run artifacts in ZBUILD_ARTIFACT_DIR covers: RQGUAR-1
DSFRSH-2[no-code]: A new run of the same issue never skips a stage due to prior run output; the dispatch-unit skip guard is conditional on resume_mode so it does not activate for fresh runs covers: RQGUAR-2
  Given: An issue has prior completed runs with artifacts present in the git state branch; a new run is started with no --resume flag and no status=interrupted state file
  When: The dispatch loop runs
  Then: Every stage emits a stage.start event
  And: No stage.skip event is emitted for any stage
DSDLGT-1[code]: The hydrate plugin's hydrate_run calls _artifact_persist_put_back so artifacts placed by the resume path appear at the same filesystem paths as those a hydrate run would produce covers: RQHYDR-1
  Given: hydrate_run is about to execute; _artifact_persist_put_back is overridden in the test environment with a sentinel-writing function
  When: hydrate_run executes
  Then: The sentinel file is written, confirming hydrate_run reached _artifact_persist_put_back
DSCYCL-1[no-code]: The pipeline fixtures used by resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, resume-loop-state-test.sh, and resume-entry-points-test.sh each contain a stage of type: cycle, verified by an assert_contains tagged [#1805/DSCYCL-1] in each file, ensuring RQRESU-4, RQLOOP-1, RQFROM-2, RQFROM-3, and RQPATH-1 tests run against a cyclic pipeline covers: RQTEST-1
REMOVED: DSDISP-1 — id collides with requirement code RQDISP-1 added by intake; the SPEC is preserved as DSDSPK-1
REMOVED: DSBNDY-1 — described file contents ("contains both…"), which no test can prove; RQADR-2 is fully covered by DSAMDR-2; the two sides of the boundary are pinned by DSRHYD-1 (resume) and DSFRSH-1 (new-run)
REMOVED: DSLEGC-1 — RQDISP-1 is now covered by DSSKIP-1[code], which tests the dispatch-unit skip guard directly (runner.sh:3442, 3724); no [done] SPEC needs to cite legacy-linear-loop evidence
WIRING:
core/pipeline/runner.sh
core/pipeline/cycle-orchestrator.sh
plugins/tool/hydrate/plugin.sh
TESTFILES:
DSRHYD-1: tests/integration/resume-rehydrate-test.sh
DSRHYD-2: tests/integration/resume-rehydrate-test.sh
DSFSTG-1: tests/integration/from-stage-rehydrate-test.sh
DSFSTG-2: tests/integration/from-stage-rehydrate-test.sh
DSAMDR-1: tests/integration/resume-rehydrate-test.sh
DSAMDR-2: tests/integration/resume-rehydrate-test.sh
DSITER-1: tests/integration/resume-loop-state-test.sh
DSCMBR-1: tests/integration/resume-loop-state-test.sh
DSSKIP-1: tests/integration/resume-rehydrate-test.sh
DSDSPK-1: tests/integration/resume-rehydrate-test.sh
DSENTR-1: tests/integration/resume-entry-points-test.sh
DSENTR-2: tests/integration/resume-entry-points-test.sh
DSFRSH-1: tests/integration/resume-rehydrate-test.sh
DSFRSH-2: tests/integration/resume-rehydrate-test.sh
DSDLGT-1: tests/unit/hydrate-stage-test.sh
DSCYCL-1: tests/integration/resume-rehydrate-test.sh tests/integration/from-stage-rehydrate-test.sh tests/integration/resume-loop-state-test.sh tests/integration/resume-entry-points-test.sh
```

```supersedes
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory writes intake-result.json and the runner snapshots it; verify P2.T1 (rc=0) still passes with DSRHYD-2 fail-closed in effect
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard (step 6), inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: the DSITER-1 fix in cycle-orchestrator.sh changes fresh-run iteration behavior; iteration count assertions may need updating. No stage.start assertions for cycle members should be added — the erroneous `_cd_iter > 0` guard (which fired for all runs) is removed (Gap 7, issue-acceptance finding 2); if stage.start count assertions for cycle members in fresh runs were added, they must be removed
```

## Findings

**Finding 1 — All SPECs named:** DSRHYD-1/2 (resume hydration), DSFSTG-1/2 (from-stage), DSAMDR-1/2 (ADR amendments), DSITER-1 (iteration state — count restoration), DSCMBR-1 (cycle member skip within interrupted iteration), DSSKIP-1 (skip-complete in dispatch-unit path), DSDSPK-1 (dispatch interrupted stage k), DSENTR-1 (entry points rehydration), DSENTR-2 (auto-resume state discovery from `runs/<run_id>/` via `latest` symlink), DSFRSH-1/2 (fresh run), DSDLGT-1 (hydrate delegation), DSCYCL-1 (cycle fixture in all 4 required test files). REMOVED: RQDISP-1 (id collision), DSBNDY-1 (described file contents), DSLEGC-1 (covered by DSSKIP-1[code]). DSCYCM-1 and DSGUAR-3 were added only in failing design attempts that never passed the design checker — they were never in an accepted design and cannot appear as REMOVED tombstones.

**Finding 2 — covers: fields use requirement IDs:** All SPECs name actual requirement IDs: RQRESU-1, RQRESU-2, RQRESU-3, RQFROM-1, RQFROM-2, RQFROM-3, RQRESU-4, RQLOOP-1, RQPATH-1, RQGUAR-1, RQGUAR-2, RQADR-1, RQADR-2, RQHYDR-1, RQTEST-1, RQDISP-1.

**Finding 3 — All 16 requirements covered:** RQRESU-1: DSRHYD-1. RQRESU-2: DSRHYD-1, DSRHYD-2. RQRESU-3: DSSKIP-1, DSDSPK-1. RQRESU-4: DSRHYD-1, DSSKIP-1, DSDSPK-1. RQFROM-1: DSFSTG-1. RQFROM-2: DSFSTG-1. RQFROM-3: DSFSTG-2. RQLOOP-1: DSITER-1 (iteration count), DSCMBR-1 (member-stage skip within interrupted iteration). RQPATH-1: DSENTR-1, DSENTR-2. RQGUAR-1: DSFRSH-1. RQGUAR-2: DSFRSH-2. RQADR-1: DSAMDR-1. RQADR-2: DSAMDR-2. RQHYDR-1: DSRHYD-1, DSDLGT-1. RQTEST-1: DSCYCL-1 (covers all 4 required test files: resume-rehydrate-test.sh for RQRESU-4, resume-loop-state-test.sh for RQLOOP-1, from-stage-rehydrate-test.sh for RQFROM-2/RQFROM-3, resume-entry-points-test.sh for RQPATH-1). RQDISP-1: DSSKIP-1.

**Finding 4 — Implementation state (verified):** `_artifact_persist_put_back` in artifact-persist.sh ✓; `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓; `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓; hydrate plugin line 162 calls `_artifact_persist_put_back` ✓; exit 1 for missing artifacts at runner.sh:3920 ✓; dispatch-unit skip guard cycle:*: runner.sh:3442 ✓; dispatch-unit skip guard stage:*: runner.sh:3728 ✓; stage k falls through to `eb_emit_event "stage.start"` ✓.

**Finding 5 — Cycle orchestrator guard:** cycle-orchestrator.sh:2337 wraps `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then`; flag consumed at line 2343 (`_ZBUILD_RESUME_ACTIVE=false`); else branch sets `_start_iter=1`. Already in branch. Step 6 is a confirm/verify step. resume-loop-state-test.sh must export `_ZBUILD_RESUME_ACTIVE=true` before calling `cycle_orchestrator_run` directly.

**Finding 6 — DSSKIP-1 claim narrowed:** Complete-stage branch in dispatch-unit `stage:*` arm: `continue` when artifact present, `return 1` when absent. DSSKIP-1 covers artifact-present path only. DSRHYD-2 covers absent-artifact case.

**Finding 7 — DSFRSH-1 is [no-code]:** Fresh runs never had a dispatch-unit skip guard, so the [no-code] test passes on pre-change code too.

**Finding 8 — ADR amendment greppability:** DSAMDR-1 and DSAMDR-2 tests grep for required amendment text in the ADR files.

**Finding 9 — DSFSTG-2 unique phrase:** "has no restorable primary artifact" — unique to `_runner_from_stage_preflight`, absent from old code.

**Finding 10 — artifact-persist.sh in scope is correct:** `core/state/artifact-persist.sh` is created by this change to satisfy RQHYDR-1 (rehydration must follow the same path as the hydrate plugin). This file IS touched by the change — it is added to the scope block because the scope block must list every file the change touches. Removing it would leave the scope incomplete. The design check finding saying "the issue does not ask for it" conflates an issue's illustrative file list with an exhaustive scope list; RQHYDR-1's directive to reuse the hydrate path motivates the extraction and the file is a direct implementation artifact.

**Finding 16 — Dispatch-unit skip guards are new code:** guards at runner.sh:3442, 3728 added by this branch. DSSKIP-1 is [code]. No pre-change evidence available.

**Finding 17 — RQORDE-1 removed by intake:** DSAMDR-1's covers field is `covers: RQADR-1` only.

**Finding 19 — DSAMDR-2 covers §6 Enforced by citations:** DSAMDR-2 specifies adding citations for DSFRSH-2 (new-run side) and DSENTR-1 (resume side) to ADR-050 §6's Enforced by section.

**Finding 20 — _cd_iter > 0 guard is WRONG:** Issue-acceptance finding 2 confirms the `_cd_iter > 0` unconditional stage.start guard fires for every dispatch in every run (`_cd_iter` starts at 1), changing fresh-run event sequences and breaking the golden files. This violates RQGUAR-1. The guard must be removed. DSDSPK-1's stage.start for cycle stage k's interrupted member comes from the DSCMBR-1 `resume_first_iter=true` path explicitly emitting stage.start for the non-complete member; it does not require an unconditional iter guard.

**Finding 21 — RQPATH-1 auto-resume state discovery gap:** Auto-resume elif (runner.sh:2174) tests flat path only; per-run layout stores at `runs/<run_id>/pipeline-state.json`. Fix: check `$state_dir/latest/pipeline-state.json` when flat path absent. DSENTR-2[code] tests this without ZBUILD_STATE_FILE set.

**Finding 22 — _ZBUILD_RESUME_ACTIVE lifecycle correct:** Flag sole purpose is `_start_iter` selection; consumed before the loop; not a general resume broadcast.

**Finding 23 — DSCMBR-1[code] implements DSDSPK-1 for cycle stages:** RQLOOP-1 says "resumes at the interrupted stage of that round" — requires both DSITER-1 (right iteration) and DSCMBR-1 (skip complete members, emit stage.start for interrupted member). The DSCMBR-1 `resume_first_iter=true` path: (a) skips complete members (no stage.start, no dispatch); (b) explicitly emits stage.start for the non-complete (interrupted) member then dispatches normally. This is the ONLY path that emits stage.start for cycle members; fresh runs and later resumed iterations receive no stage.start for cycle members through this code path, preserving golden file behavior.

**Finding 24 — golden files in scope:** `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden` are in scope. If the branch changed them by adding cycle-member stage.start events from the erroneous `_cd_iter > 0` guard, those changes must be reverted.

**Finding 25 — DSENTR-2 ZBUILD_STATE_FILE constraint:** Issue-acceptance finding 1 confirms the DSENTR-2 test sets `ZBUILD_STATE_FILE="$P2_STATE_FILE"` at line 219, making the symlink branch guard false. The design spec is correct (Given says ZBUILD_STATE_FILE must be unset). The DSENTR-2 step carries a CRITICAL note to enforce this constraint on the build stage.

**Finding 26 — RQTEST-1 coverage widened:** DSCYCL-1 covers all four required test files (resume-rehydrate-test.sh for RQRESU-4, resume-loop-state-test.sh for RQLOOP-1, from-stage-rehydrate-test.sh for RQFROM-2/RQFROM-3, resume-entry-points-test.sh for RQPATH-1); update steps for resume-loop-state-test.sh and resume-entry-points-test.sh each include an [#1805/DSCYCL-1] assertion item.

**Finding 27 — pipeline.skip_to_stage in combined resume+from-stage mode (lens-correctness-design finding 1):** runner.sh:2963 emits `pipeline.skip_to_stage` whenever `--from-stage` is active, including when `--resume` is also active. RQFROM-2 says the event must not be FOLLOWED BY running an earlier stage — that constraint is met because rehydration and the dispatch-loop skip guards prevent earlier-stage dispatch in both modes. The event's emission is therefore RQFROM-2-compliant. No code change is needed to suppress it; DSFSTG-1 makes the boundary explicit via an additional Then clause (Gap 10 above). No new SPEC is required; the existing DSFSTG-1[code] covers RQFROM-2 and its test will verify that no stage before <s> is dispatched after the event in either mode.
