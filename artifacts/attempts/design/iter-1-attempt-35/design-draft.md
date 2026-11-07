# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1. Additionally, within the first resumed iteration, `_cycle_dispatch` must skip cycle member stages already marked complete in persisted state, so the first dispatched cycle member is the one that was actually interrupted.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed** — `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed** — exit 1 path at runner.sh:3920 (comment: "ADR-006 §3.6 (#1805): fail closed").
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed** — `_runner_from_stage_preflight` at runner.sh:1733.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, breaking nested loops. **Fixed** — cycle-orchestrator.sh:2337 wraps the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then`; flag is consumed immediately at line 2343 (`_ZBUILD_RESUME_ACTIVE=false`, comment: "Consume the flag: nested cycles and subsequent re-entries start at 1"); fresh/nested-loop re-entries take the else branch setting `_start_iter=1`.
- Gap 5 — dispatch-unit loop (cycle:* arm, stage:* arm) lacked skip-on-complete guard for resume mode; only the legacy linear loop had one. **Fixed** — guards at runner.sh:3442 (cycle:*) and runner.sh:3724-3760 (stage:*), both conditioned on `$resume_mode`; added by this branch.
- Gap 6 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**
- Gap 7 — `_cycle_dispatch` (runner.sh:3204) emits `stage.start` for ALL cycle member dispatches at `iter > 0`. **DESIGN CORRECTION** — the previously proposed step 7a (guard with `${_ZBUILD_RESUME_ACTIVE:-false} == true`) is WRONG: cycle-orchestrator.sh:2343 sets `_ZBUILD_RESUME_ACTIVE=false` before the iteration loop begins, so the flag is always false when `_cycle_dispatch` is called. Applying that guard would suppress `stage.start` for cycle members even during resume, breaking DSPK-1. The correct behavior is the `if [[ "$_cd_iter" -gt 0 ]]; then` guard in `_cycle_dispatch`. The design checker confirmed the evidence comment at runner.sh:3211 ("Emit stage.start for cycle members") was added by this branch; CYCM-1[done] is therefore not tenable and is removed. FRSH-1[no-code] covers GUAR-1: the FRSH-1 test verifies fresh runs dispatch all stages with no skips; cycle members additionally emitting stage.start at iter > 0 does not constitute a stage skip and is not a GUAR-1 violation. The cycle-member-dispatch-events-test.sh update (supersedes) documents this behavior. Step 7a is removed.
- Gap 8 — runner.sh auto-resume check (line 2174) tests `[[ -f "$state_file" ]]` where `state_file = $state_dir/pipeline-state.json` (the flat default root path). But the per-run layout (ADR-059 §1) stores state at `runs/<run_id>/pipeline-state.json`, not at the root. The `latest` symlink at `$(zbuild_layout_state_root)/latest` points to the most-recent per-run dir and is already used by `_find_state_file` in `scripts/zbuild`, but runner.sh's auto-resume check never consults it. Result: without ZBUILD_STATE_FILE set, auto-resume never fires for any per-run default layout. All existing auto-resume tests mask this gap by setting ZBUILD_STATE_FILE explicitly. **NOT YET FIXED** — extend the auto-resume elif to check `$state_dir/latest/pipeline-state.json` when the flat path does not exist, and update state_dir/state_file to the resolved per-run path when `auto_resume` fires (step 7b).
- Gap 9 — `_cycle_dispatch` (runner.sh:~3204) emits `stage.start` for ALL cycle member dispatches at `_cd_iter > 0` with no skip-on-complete guard. Within the first resumed iteration (iter k, where the run was interrupted), member stages already marked complete must be skipped so the first dispatched member is the interrupted stage. SKIP-1's dispatch-unit skip guard applies to top-level `_TPL_DISPATCH_UNITS` entries only; `_cycle_dispatch` is called from inside the cycle orchestrator and has no equivalent guard. **NOT YET FIXED** — the cycle orchestrator must signal to `_cycle_dispatch` whether it is dispatching the first resumed iteration, and `_cycle_dispatch` must skip members already marked complete in persisted state when that signal is set (step for CMBR-1).

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into `_artifact_persist_put_back <from> <to>` in `core/state/artifact-persist.sh`. Redirect hydrate's `hydrate_run` call site to the new function. At the resume entry point in runner.sh, export `_ZBUILD_RESUME_ACTIVE=true` (already at line 2862). In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi`; the flag is consumed immediately after reading (`_ZBUILD_RESUME_ACTIVE=false`) so nested cycles and subsequent re-entries always start at iter=1. The dispatch-unit loop's skip-on-complete guards are conditioned on `$resume_mode` (not unconditionally), ensuring fresh runs never skip. Change the stale-artifact branch from warn+continue to exit 1 (already done at runner.sh:3920). Add `_runner_from_stage_preflight` called before the dispatch loop when `--from-stage` is active. In `_cycle_dispatch` (runner.sh:3204), the `if [[ "$_cd_iter" -gt 0 ]]; then` guard emits `stage.start` for all cycle member dispatches at iter > 0 — including stage k during resume (DSPK-1) and all iters in fresh runs; this is correct and no additional guard is needed. In the auto-resume elif branch (runner.sh:2174), extend state discovery to check `$state_dir/latest/pipeline-state.json` when `$state_dir/pipeline-state.json` does not exist; when `auto_resume` recommendation fires via the `latest` path, update state_dir to the resolved per-run dir and state_file to `state_dir/pipeline-state.json` so artifact operations use the correct directory. In `_cycle_dispatch` (runner.sh:~3204) add a skip-on-complete guard controlled by a new `resume_first_iter` local flag: the cycle orchestrator sets this flag to `true` only for the first iteration dispatched during a resume (when `_start_iter > 1`); `_cycle_dispatch` with `resume_first_iter=true` checks the cycle member stage's persisted status and skips (no stage.start, no dispatch) any member already marked complete; the flag is passed as an argument so it has no interaction with `_ZBUILD_RESUME_ACTIVE` (already consumed). Amend ADR-006 and ADR-050.

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
```

```steps
- Amend docs/adr/ADR-006-resume-contract.md: insert step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes) and add enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) inline | areas: docs/adr/ADR-006-resume-contract.md
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs); update §6's Enforced by entry to also cite resume-rehydrate-test.sh (new-run side: FRSH-2) and resume-entry-points-test.sh (resume side: ENTR-1) alongside the existing resume-default-test.sh R5–R11 citation | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh (no-clobber copy skipping stage-io/); body identical to current _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh hydrate_run call site (line 162) to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: add [#1805/DLGT-1] section that overrides _artifact_persist_put_back with a sentinel-writing function, runs hydrate_run, and asserts the sentinel was written — fails when plugin reverted to inline _hydrate_put_back | areas: tests/unit/hydrate-stage-test.sh
- Confirm _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: the `_ZBUILD_RESUME_ACTIVE` guard (wrapping `_persisted_iter` read; consuming flag immediately with `_ZBUILD_RESUME_ACTIVE=false`; else branch sets `_start_iter=1`) is already in place — verify it is present and correct | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, confirm `export _ZBUILD_RESUME_ACTIVE=true` is present immediately after the _runner_resume_rehydrate call (runner.sh:2862); do NOT set it for fresh runs; confirm `_cycle_dispatch` (runner.sh:3204) emits `stage.start` for `_cd_iter > 0` unconditionally — this is correct (the flag is consumed before the loop so a `_ZBUILD_RESUME_ACTIVE` guard here would suppress stage.start even during resume) | areas: core/pipeline/runner.sh
- In runner.sh auto-resume elif branch (line 2174), extend state discovery: when `$state_dir/pipeline-state.json` does not exist and `$state_dir/latest` is a symlink to a directory containing `pipeline-state.json`, use `$state_dir/latest/pipeline-state.json` as the candidate state file; when `auto_resume` recommendation fires via this path, update state_dir to the resolved per-run directory (via readlink -f) and state_file to `$state_dir/pipeline-state.json`; ensures auto-resume works for the per-run default layout (ADR-059 §1) without requiring ZBUILD_STATE_FILE | areas: core/pipeline/runner.sh
- Update tests/integration/resume-entry-points-test.sh: add [#1805/ENTR-2] sub-case that sets ZBUILD_STATE_ROOT to a temp directory, creates `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with status=interrupted and intake=complete, creates a `$ZBUILD_STATE_ROOT/latest` symlink pointing to that dir, invokes the runner with ZBUILD_STATE_FILE and ZBUILD_STATE_DIR unset, and asserts: pipeline.resume event emitted (auto-resume fired), completed-stage artifacts restored, no stage.start for intake | areas: tests/integration/resume-entry-points-test.sh
- Update tests/integration/cycle-member-dispatch-events-test.sh to expect stage.start events for cycle members at iter > 0 (the `_cd_iter > 0` guard in `_cycle_dispatch` emits stage.start for all cycle member dispatches, fresh and resume); also confirm cycle-inner-iter-resets-per-outer-iter-test.sh, nested-loop-rounds-test.sh, and nested-loop-rounds-build-test.sh pass after the cycle-orchestrator ITER-1 guard fix | areas: tests/integration/cycle-member-dispatch-events-test.sh, tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh
- Update tests/integration/resume-loop-state-test.sh: (1) add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the cycle_orchestrator_run call so the [#1805/ITER-1] assertion "first dispatched iter is 2" reaches the guard; (2) add [#1805/CMBR-1] sub-case with a fixture where iter 1 fully completed and iter 2 ran build (complete) then was interrupted before test; set up persisted state accordingly; invoke the runner with --resume; assert no stage.start event for "build" in iter 2 and a stage.start event for "test" in iter 2 | areas: tests/integration/resume-loop-state-test.sh
- In `_cycle_dispatch` (runner.sh:~3204) and the cycle orchestrator body (cycle-orchestrator.sh), add a skip-on-complete guard for the first resumed iteration: the cycle orchestrator passes `resume_first_iter=true` only when dispatching members of `_start_iter` during a resume (i.e., `_start_iter > 1` and current iter == `_start_iter`); `_cycle_dispatch` with that flag checks the cycle member stage's status in persisted state and skips (no stage.start) any member already marked complete — this is the CMBR-1 fix (Gap 9) | areas: core/pipeline/runner.sh, core/pipeline/cycle-orchestrator.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix grep-c anti-pattern sites — replace with wc -l; (2) add --no-resume flag to the fresh-run sub-case; (3) remove stale cycled-dispatch assert_gt block; (4) retag the assert_contains type:cycle line to [#1805/CYCL-1]; (5) add [#1805/FRSH-1] assertion in the --no-resume sub-case verifying all stages dispatched from stage 1 with no stage.skip events emitted; (6) add [#1805/DSPK-1] assertion in the resume sub-case verifying stage k emits stage.start; (7) add [#1805/FRSH-2] assertion in a sub-case with prior run state present and no --resume flag, verifying no stages are skipped due to prior run output; (8) add [#1805/SKIP-1] assertion in the resume sub-case verifying no stage.start for a stage already marked complete whose artifact is present after rehydration | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: (1) fix FSTG-1 zero-count grep-c with wc -l; (2) retag assert_contains type:cycle to [#1805/CYCL-1]; (3) change FSTG-2 assert_contains to check for "has no restorable primary artifact" | areas: tests/integration/from-stage-rehydrate-test.sh
- Verify tests/integration/resume-entry-points-test.sh: three entry-path assertions tagged [#1805/ENTR-1] | areas: tests/integration/resume-entry-points-test.sh
- Verify tests/integration/pipeline-resume-test.sh: intake's primary artifact pre-written to ZBUILD_ARTIFACT_DIR before the --resume run | areas: tests/integration/pipeline-resume-test.sh
- Verify tests/integration/resume-after-sigint-test.sh: mock_plugin_factory "intake" writes intake-result.json; runner snapshots it after Phase 1; resume rehydration restores it; P2.T1 (rc=0) still passes with RHYD-2 fail-closed in effect | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
RHYD-1[code]: On resume, before the dispatch loop, completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical to their state at interruption, and no stage.start event is emitted for them covers: RESU-1 RESU-2 RESU-4 HYDR-1
  Given: A run has been interrupted; stage k-1 is marked complete with its artifacts present in the git state branch; stage k was the interrupted stage
  When: The run is resumed via any of the three entry paths (--resume flag, auto-resume on status=interrupted, or zbuild pipeline resume --run-id)
  Then: The completed stage's artifacts appear in ZBUILD_ARTIFACT_DIR byte-identical to their state at the time of interruption
  And: No stage.start event is emitted for the completed stage
RHYD-2[code]: A complete stage whose primary artifact cannot be rehydrated causes exit 1 before any stage.start event is emitted covers: RESU-2
  Given: A run is being resumed; a stage is marked complete in persisted state; its primary artifact is absent from both disk and the git state branch after rehydration attempt
  When: The runner processes that stage during resume rehydration
  Then: The runner exits 1
  And: No stage.start event has been emitted for any stage
FSTG-1[code]: --from-stage <s> rehydrates all stages before <s> and dispatches <s> as the first stage covers: FROM-1 FROM-2
  Given: A previous run completed stages before <s>; their artifacts are present in the git state branch; a new invocation uses --from-stage <s>
  When: The runner starts with --from-stage <s>
  Then: The artifacts from every stage before <s> appear in ZBUILD_ARTIFACT_DIR before the dispatch loop starts
  And: Stage <s> is dispatched as the first stage (a stage.start event is emitted for <s>)
  And: No stage.start event is emitted for any stage before <s>
FSTG-2[code]: --from-stage <s> when a prior stage has no restorable artifact emits a diagnostic and exits 1 before any stage.start event covers: FROM-3
  Given: --from-stage <s> is active; at least one stage before <s> has no restorable primary artifact in the git state branch
  When: The runner performs the from-stage preflight check
  Then: The diagnostic phrase "has no restorable primary artifact" appears on stderr
  And: The runner exits 1 before any stage.start event is emitted
AMDR-1[no-code]: ADR-006-resume-contract.md amended with step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes); enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: ADR-1
AMDR-2[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant "never skip a stage on prior output" applies to new runs; a resume continues the same run and is governed by ADR-006; and §6's Enforced by section updated to cite resume-rehydrate-test.sh (FRSH-2 for the new-run side) and resume-entry-points-test.sh (ENTR-1 for the resume side) covers: ADR-2
ITER-1[code]: Cycle orchestrator reads current_iter from persisted state on resume and starts the iteration loop from that value; fresh runs and nested-loop re-entries always start at iter=1 covers: LOOP-1
  Given: A run is being resumed; persisted state records cycle_iterations[CYCLE_ID].current_iter=2 (iter 1 completed before interruption); _ZBUILD_RESUME_ACTIVE=true is exported
  When: The cycle orchestrator's run body executes
  Then: The iteration loop starts at iter 2, not iter 1
  And: No stage.start event is emitted for any iter-1 stage
  And: When _ZBUILD_RESUME_ACTIVE is false or unset (fresh run or nested-loop re-entry), the loop starts at iter=1
CMBR-1[code]: On resume, within the interrupted iteration, cycle member stages already marked complete in persisted state are skipped; the first dispatched cycle member is the interrupted stage covers: LOOP-1
  Given: A run is being resumed; in the interrupted iteration (iter k), member stage "build" completed and member stage "test" was interrupted before completing; persisted state records build as complete and test as in-progress within iter k
  When: The cycle orchestrator dispatches members of iter k
  Then: No stage.start event is emitted for "build" (already complete in iter k)
  And: stage.start is emitted for "test" (the interrupted member of iter k)
SKIP-1[code]: On resume, the dispatch-unit loop skips a stage marked complete whose primary artifact is present after rehydration, emitting no stage.start for that stage covers: RESU-3 RESU-4 DISP-1
  Given: A run is being resumed; a stage is marked complete in persisted state and its primary artifact is present in ZBUILD_ARTIFACT_DIR after rehydration
  When: The dispatch-unit loop reaches that stage
  Then: No stage.start event is emitted for that stage
DSPK-1[code]: On resume, stage k (the interrupted stage) is dispatched and emits stage.start covers: RESU-3 RESU-4
  Given: A run with stages 1…N was interrupted during stage k; stages 1…k-1 are marked complete with their artifacts present in ZBUILD_ARTIFACT_DIR after rehydration
  When: The dispatch loop reaches stage k during resume
  Then: Stage k emits a stage.start event
ENTR-1[code]: All three resume entry paths (--resume flag, auto-resume on status=interrupted, zbuild pipeline resume --run-id) restore completed-stage artifacts before the dispatch loop covers: PATH-1
  Given: A run has been interrupted and its state is persisted in runs/<run_id>/
  When: The run is resumed via any of the three entry paths in turn
  Then: Completed-stage artifacts appear in ZBUILD_ARTIFACT_DIR before any stage.start event is emitted, for each of the three entry paths independently
  And: No stage.start event is emitted for any stage marked complete in the interrupted run's state
ENTR-2[code]: On auto-resume, when no ZBUILD_STATE_FILE is set and the most recent run's state is under the per-run path `runs/<run_id>/`, the runner finds it via the `latest` symlink and enters resume_mode covers: PATH-1
  Given: A previous run stored state at `$state_root/runs/<run_id>/pipeline-state.json` with status=interrupted; `$state_root/latest` symlinks to that per-run dir; ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset
  When: The runner is invoked with no --resume flag and ZBUILD_STATE_FILE not set
  Then: resume_mode is set to true (pipeline.resume event is emitted)
  And: Completed-stage artifacts are restored from the per-run state directory before any stage.start event
FRSH-1[no-code]: A fresh run dispatches all stages from stage 1 with no stage skipped due to prior state and no prior-run artifacts in ZBUILD_ARTIFACT_DIR covers: GUAR-1
FRSH-2[no-code]: A new run of the same issue never skips a stage due to prior run output; the dispatch-unit skip guard is conditional on resume_mode so it does not activate for fresh runs covers: GUAR-2
  Given: An issue has prior completed runs with artifacts present in the git state branch; a new run is started with no --resume flag and no status=interrupted state file
  When: The dispatch loop runs
  Then: Every stage emits a stage.start event
  And: No stage.skip event is emitted for any stage
DLGT-1[code]: The hydrate plugin's hydrate_run calls _artifact_persist_put_back so artifacts placed by the resume path appear at the same filesystem paths as those a hydrate run would produce covers: HYDR-1
  Given: hydrate_run is about to execute; _artifact_persist_put_back is overridden in the test environment with a sentinel-writing function
  When: hydrate_run executes
  Then: The sentinel file is written, confirming hydrate_run reached _artifact_persist_put_back
CYCL-1[no-code]: The test fixtures used by resume-rehydrate-test.sh and from-stage-rehydrate-test.sh each contain a pipeline stage of type: cycle, verified by an assert_contains tagged [#1805/CYCL-1] in each file, ensuring RESU-1 through FROM-1 tests run against a cyclic pipeline covers: TEST-1
REMOVED: DISP-1 — id collides with requirement code DISP-1 added by intake; the SPEC is preserved as DSPK-1
REMOVED: BNDY-1 — described file contents ("contains both…"), which no test can prove; ADR-2 is fully covered by AMDR-2; the two sides of the boundary are pinned by RHYD-1 (resume) and FRSH-1 (new-run)
REMOVED: LEGC-1 — DISP-1 is now covered by SKIP-1[code], which tests the dispatch-unit skip guard directly (runner.sh:3442, 3724); no [done] SPEC needs to cite legacy-linear-loop evidence
WIRING:
core/pipeline/runner.sh
core/pipeline/cycle-orchestrator.sh
plugins/tool/hydrate/plugin.sh
TESTFILES:
RHYD-1: tests/integration/resume-rehydrate-test.sh
RHYD-2: tests/integration/resume-rehydrate-test.sh
FSTG-1: tests/integration/from-stage-rehydrate-test.sh
FSTG-2: tests/integration/from-stage-rehydrate-test.sh
AMDR-1: tests/integration/resume-rehydrate-test.sh
AMDR-2: tests/integration/resume-rehydrate-test.sh
ITER-1: tests/integration/resume-loop-state-test.sh
CMBR-1: tests/integration/resume-loop-state-test.sh
SKIP-1: tests/integration/resume-rehydrate-test.sh
DSPK-1: tests/integration/resume-rehydrate-test.sh
ENTR-1: tests/integration/resume-entry-points-test.sh
ENTR-2: tests/integration/resume-entry-points-test.sh
FRSH-1: tests/integration/resume-rehydrate-test.sh
FRSH-2: tests/integration/resume-rehydrate-test.sh
DLGT-1: tests/unit/hydrate-stage-test.sh
CYCL-1: tests/integration/resume-rehydrate-test.sh tests/integration/from-stage-rehydrate-test.sh
```

```supersedes
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory writes intake-result.json and the runner snapshots it; verify P2.T1 (rc=0) still passes with RHYD-2 fail-closed in effect
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard (step 6), inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: (1) the ITER-1 fix in cycle-orchestrator.sh restores correct iteration counts; (2) update assertions to expect stage.start for cycle members at _cd_iter > 0 — this behavior (emitting stage.start for cycle member dispatches) is introduced by this branch's _cycle_dispatch changes; the test update documents the new expectation
```

## Findings

**Finding 1 — All SPECs named:** RHYD-1/2 (resume hydration), FSTG-1/2 (from-stage), AMDR-1/2 (ADR amendments), ITER-1 (iteration state — count restoration), CMBR-1 (cycle member skip within interrupted iteration), SKIP-1 (skip-complete in dispatch-unit path), DSPK-1 (dispatch interrupted stage k), ENTR-1 (entry points rehydration), ENTR-2 (auto-resume state discovery from `runs/<run_id>/` via `latest` symlink), FRSH-1/2 (fresh run), DLGT-1 (hydrate delegation), CYCL-1 (cycle fixture). REMOVED: DISP-1 (id collision), BNDY-1 (described file contents), LEGC-1 (covered by SKIP-1[code]). CYCM-1 and GUAR-3 were added only in failing design attempts that never passed the design checker — they were never in an accepted design and cannot appear as REMOVED tombstones.

**Finding 2 — covers: fields use requirement IDs:** All SPECs name actual requirement IDs: RESU-1, RESU-2, RESU-3, RESU-4, FROM-1, FROM-2, FROM-3, LOOP-1, PATH-1, GUAR-1, GUAR-2, ADR-1, ADR-2, HYDR-1, TEST-1, DISP-1.

**Finding 3 — All 16 requirements covered:** RESU-1: RHYD-1. RESU-2: RHYD-1, RHYD-2. RESU-3: SKIP-1, DSPK-1. RESU-4: RHYD-1, SKIP-1, DSPK-1. FROM-1: FSTG-1. FROM-2: FSTG-1. FROM-3: FSTG-2. LOOP-1: ITER-1 (iteration count), CMBR-1 (member-stage skip within interrupted iteration). PATH-1: ENTR-1, ENTR-2. GUAR-1: FRSH-1 (no-code test verifying fresh runs dispatch all stages with no skips). GUAR-2: FRSH-2. ADR-1: AMDR-1. ADR-2: AMDR-2. HYDR-1: RHYD-1, DLGT-1. TEST-1: CYCL-1. DISP-1: SKIP-1.

**Finding 4 — Implementation state (verified):** `_artifact_persist_put_back` in artifact-persist.sh ✓; `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓; `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓; hydrate plugin line 162 calls `_artifact_persist_put_back` ✓; exit 1 for missing artifacts at runner.sh:3920 ✓; dispatch-unit skip guard cycle:*: runner.sh:3442 ✓; dispatch-unit skip guard stage:*: runner.sh:3728 ✓; stage k falls through to `eb_emit_event "stage.start"` ✓.

**Finding 5 — Cycle orchestrator guard:** cycle-orchestrator.sh:2337 wraps `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then`; flag consumed at line 2343 (`_ZBUILD_RESUME_ACTIVE=false`); else branch sets `_start_iter=1`. Already in branch. Step 6 is a confirm/verify step. resume-loop-state-test.sh must export `_ZBUILD_RESUME_ACTIVE=true` before calling `cycle_orchestrator_run` directly.

**Finding 6 — SKIP-1 claim narrowed:** Complete-stage branch in dispatch-unit `stage:*` arm: `continue` when artifact present, `return 1` when absent. SKIP-1 covers artifact-present path only. RHYD-2 covers absent-artifact case.

**Finding 7 — FRSH-1 is [no-code]:** Fresh runs never had a dispatch-unit skip guard, so the [no-code] test passes on pre-change code too.

**Finding 8 — ADR amendment greppability:** AMDR-1 and AMDR-2 tests grep for required amendment text in the ADR files.

**Finding 9 — FSTG-2 unique phrase:** "has no restorable primary artifact" — unique to `_runner_from_stage_preflight`, absent from old code.

**Finding 16 — Dispatch-unit skip guards are new code:** guards at runner.sh:3442, 3728 added by this branch. SKIP-1 is [code]. No pre-change evidence available.

**Finding 17 — ORDE-1 removed by intake:** AMDR-1's covers field is `covers: ADR-1` only.

**Finding 19 — AMDR-2 covers §6 Enforced by citations:** AMDR-2 specifies adding citations for FRSH-2 (new-run side) and ENTR-1 (resume side) to ADR-050 §6's Enforced by section.

**Finding 20 — _cd_iter > 0 guard and CYCM-1 removal:** cycle-orchestrator.sh:2343 sets `_ZBUILD_RESUME_ACTIVE=false` before the iteration loop, so the flag is always false when `_cycle_dispatch` is called. The `_cd_iter > 0` guard fires for stage k during resume (DSPK-1) and for all iters in fresh runs. The design checker confirmed the evidence comment `"Emit stage.start for cycle members"` at runner.sh:3211 was added by this branch; accordingly CYCM-1[done] is not tenable and is removed. FRSH-1[no-code] covers GUAR-1: fresh runs dispatch all stages with no skips; cycle members additionally emitting stage.start at iter > 0 does not constitute a stage skip and is not a GUAR-1 violation. The cycle-member-dispatch-events-test.sh update (supersedes) documents this behavior. Step 7a removed.

**Finding 21 — PATH-1 auto-resume state discovery gap:** Auto-resume elif (runner.sh:2174) tests flat path only; per-run layout stores at `runs/<run_id>/pipeline-state.json`. Fix: check `$state_dir/latest/pipeline-state.json` when flat path absent. ENTR-2[code] tests this without ZBUILD_STATE_FILE set.

**Finding 22 — _ZBUILD_RESUME_ACTIVE lifecycle correct:** Flag sole purpose is `_start_iter` selection; consumed before the loop; not a general resume broadcast. No plugin should depend on it after the outer cycle orchestrator consumes it.

**Finding 23 — CMBR-1[code] added:** LOOP-1 says "resumes at the interrupted stage of that round" — requires both ITER-1 (right iteration) and CMBR-1 (skip complete members within that iteration). `_cycle_dispatch` currently emits stage.start for all members at `_cd_iter > 0` unconditionally. CMBR-1 adds `resume_first_iter` local flag passed from cycle orchestrator to `_cycle_dispatch` for the first resumed iteration only.

**Finding 24 — CYCM-1 removed; GUAR-3 never added back:** CYCM-1[done] was added in the thirty-eighth failing attempt to settle issue-acceptance finding 1 about whether the `_cd_iter > 0` guard is pre-existing. The design checker confirmed the evidence text (`core/pipeline/runner.sh:"Emit stage.start for cycle members"`) was added by this branch, making [done] untenable. CYCM-1 is removed; no tombstone is needed because CYCM-1 never appeared in an accepted design. GUAR-1 is fully covered by FRSH-1[no-code] — the FRSH-1 test verifies fresh runs dispatch all stages correctly with no skips, which is the GUAR-1 concern. GUAR-3 was likewise only in a failing attempt and needs no tombstone.
