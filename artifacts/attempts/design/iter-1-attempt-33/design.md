# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed** — `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed** — exit 1 path at runner.sh:3920 (comment: "ADR-006 §3.6 (#1805): fail closed").
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed** — `_runner_from_stage_preflight` at runner.sh:1733.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, breaking nested loops. **NOT YET FIXED** — guard with `_ZBUILD_RESUME_ACTIVE` must still be added (step 6); runner.sh already exports `_ZBUILD_RESUME_ACTIVE=true` at line 2862. The test at resume-loop-state-test.sh must export it before calling `cycle_orchestrator_run` (step 9).
- Gap 5 — dispatch-unit loop (cycle:* arm, stage:* arm) lacked skip-on-complete guard for resume mode; only the legacy linear loop had one. **Fixed** — guards at runner.sh:3442 (cycle:*) and runner.sh:3724-3760 (stage:*), both conditioned on `$resume_mode`; added by this branch.
- Gap 6 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**
- Gap 7 — `_cycle_dispatch` (runner.sh:3166) emits `stage.start` for ALL cycle member dispatches at `iter > 0`, not only during resume. This is broader than DSPK-1 requires and changes the event contract for fresh cycle-based runs. **NOT YET FIXED** — the guard at 3166 must be narrowed to `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]] && [[ "$_cd_iter" -gt 0 ]]; then` so cycle members only emit `stage.start` in resume mode (step 7a).
- Gap 8 — runner.sh auto-resume check (line 2174) tests `[[ -f "$state_file" ]]` where `state_file = $state_dir/pipeline-state.json` (the flat default root path). But the per-run layout (ADR-059 §1) stores state at `runs/<run_id>/pipeline-state.json`, not at the root. The `latest` symlink at `$(zbuild_layout_state_root)/latest` points to the most-recent per-run dir and is already used by `_find_state_file` in `scripts/zbuild`, but runner.sh's auto-resume check never consults it. Result: without ZBUILD_STATE_FILE set, auto-resume never fires for any per-run default layout. All existing auto-resume tests mask this gap by setting ZBUILD_STATE_FILE explicitly. **NOT YET FIXED** — extend the auto-resume elif to check `$state_dir/latest/pipeline-state.json` when the flat path does not exist, and update state_dir/state_file to the resolved per-run path when `auto_resume` fires (step 7b).

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into `_artifact_persist_put_back <from> <to>` in `core/state/artifact-persist.sh`. Redirect hydrate's `hydrate_run` call site to the new function. At the resume entry point in runner.sh, export `_ZBUILD_RESUME_ACTIVE=true` (already at line 2862). In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi`. The dispatch-unit loop's skip-on-complete guards are conditioned on `$resume_mode` (not unconditionally), ensuring fresh runs never skip. Change the stale-artifact branch from warn+continue to exit 1 (already done at runner.sh:3920). Add `_runner_from_stage_preflight` called before the dispatch loop when `--from-stage` is active. In `_cycle_dispatch` (runner.sh:3166), narrow the `stage.start` emission guard from `if [[ "$_cd_iter" -gt 0 ]]; then` to `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]] && [[ "$_cd_iter" -gt 0 ]]; then` — cycle members must only emit `stage.start` during resume (using the exported `_ZBUILD_RESUME_ACTIVE`, since `resume_mode` is a local variable inaccessible inside `_cycle_dispatch`). In the auto-resume elif branch (runner.sh:2174), extend state discovery to check `$state_dir/latest/pipeline-state.json` when `$state_dir/pipeline-state.json` does not exist; when `auto_resume` recommendation fires via the `latest` path, update state_dir to the resolved per-run dir and state_file to `state_dir/pipeline-state.json` so artifact operations use the correct directory. Amend ADR-006 and ADR-050.

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
- Fix _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: replace the unconditional current_iter block with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi` — fresh runs and nested-loop re-entries always start at iter=1 | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, confirm `export _ZBUILD_RESUME_ACTIVE=true` is present immediately after the _runner_resume_rehydrate call (runner.sh:2862); do NOT set it for fresh runs | areas: core/pipeline/runner.sh
- In runner.sh `_cycle_dispatch` (currently line 3166), narrow the stage.start guard from `if [[ "$_cd_iter" -gt 0 ]]; then` to `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]] && [[ "$_cd_iter" -gt 0 ]]; then` — cycle members emit stage.start only on resume; fresh-run cycle member dispatch preserves pre-branch event contract (note: `resume_mode` is a local inaccessible inside `_cycle_dispatch`; use `_ZBUILD_RESUME_ACTIVE` which is exported) | areas: core/pipeline/runner.sh
- In runner.sh auto-resume elif branch (line 2174), extend state discovery: when `$state_dir/pipeline-state.json` does not exist and `$state_dir/latest` is a symlink to a directory containing `pipeline-state.json`, use `$state_dir/latest/pipeline-state.json` as the candidate state file; when `auto_resume` recommendation fires via this path, update state_dir to the resolved per-run directory (via readlink -f) and state_file to `$state_dir/pipeline-state.json`; ensures auto-resume works for the per-run default layout (ADR-059 §1) without requiring ZBUILD_STATE_FILE | areas: core/pipeline/runner.sh
- Update tests/integration/resume-entry-points-test.sh: add [#1805/ENTR-2] sub-case that sets ZBUILD_STATE_ROOT to a temp directory, creates `$ZBUILD_STATE_ROOT/runs/<run_id>/pipeline-state.json` with status=interrupted and intake=complete, creates a `$ZBUILD_STATE_ROOT/latest` symlink pointing to that dir, invokes the runner with ZBUILD_STATE_FILE and ZBUILD_STATE_DIR unset, and asserts: pipeline.resume event emitted (auto-resume fired), completed-stage artifacts restored, no stage.start for intake | areas: tests/integration/resume-entry-points-test.sh
- Confirm tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, nested-loop-rounds-test.sh, nested-loop-rounds-build-test.sh, and cycle-member-dispatch-events-test.sh pass after the guard fix | areas: tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, tests/integration/cycle-member-dispatch-events-test.sh
- Update tests/integration/resume-loop-state-test.sh: add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the cycle_orchestrator_run call so the [#1805/ITER-1] assertion "first dispatched iter is 2" reaches the guard | areas: tests/integration/resume-loop-state-test.sh
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
tests/integration/cycle-member-dispatch-events-test.sh: broken by unconditional current_iter read causing extra iterations; same fix restores correct behaviour
```

## Findings

**Finding 1 — All SPECs named:** RHYD-1/2 (resume hydration), FSTG-1/2 (from-stage), AMDR-1/2 (ADR amendments), ITER-1 (iteration state), SKIP-1 (skip-complete in dispatch-unit path), DSPK-1 (dispatch interrupted stage k), ENTR-1 (entry points rehydration), ENTR-2 (auto-resume state discovery from `runs/<run_id>/` via `latest` symlink), FRSH-1/2 (fresh run), DLGT-1 (hydrate delegation), CYCL-1 (cycle fixture). REMOVED: DISP-1 (id collision), BNDY-1 (described file contents), LEGC-1 (covered by SKIP-1[code]).

**Finding 2 — covers: fields use requirement IDs:** All SPECs name actual requirement IDs: RESU-1, RESU-2, RESU-3, RESU-4, FROM-1, FROM-2, FROM-3, LOOP-1, PATH-1, GUAR-1, GUAR-2, ADR-1, ADR-2, HYDR-1, TEST-1, DISP-1. ORDE-1 was removed from requirements by intake (process/ordering constraint, not a code requirement); AMDR-1's covers field updated accordingly.

**Finding 3 — All 16 requirements covered:** RESU-1: RHYD-1. RESU-2: RHYD-1, RHYD-2. RESU-3: SKIP-1, DSPK-1. RESU-4: RHYD-1, SKIP-1, DSPK-1. FROM-1: FSTG-1. FROM-2: FSTG-1. FROM-3: FSTG-2. LOOP-1: ITER-1. PATH-1: ENTR-1, ENTR-2 (ENTR-1 covers rehydration across all three entry paths; ENTR-2 covers auto-resume state discovery from `runs/<run_id>/` without ZBUILD_STATE_FILE). GUAR-1: FRSH-1. GUAR-2: FRSH-2. ADR-1: AMDR-1. ADR-2: AMDR-2. HYDR-1: RHYD-1, DLGT-1. TEST-1: CYCL-1. DISP-1: SKIP-1.

**Finding 4 — Implementation state (verified):**
- `_artifact_persist_put_back` defined in artifact-persist.sh ✓
- `_artifact_persist_restore` defined in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- In-loop exit-1 for missing artifacts at runner.sh:3920 (ADR-006 §3.6 comment) ✓
- Dispatch-unit skip guard (cycle:*): `if $resume_mode && [[ -z "$skip_until_stage" ]]` at runner.sh:3442 ✓
- Dispatch-unit skip guard (stage:*): `if $resume_mode && [[ -z "$skip_until_stage" ]]` at runner.sh:3728 ✓
- Stage k dispatch: skip guard only for `stage_status == "complete"`; stage k falls through to `eb_emit_event "stage.start"` ✓

**Finding 5 — Cycle orchestrator guard (NOT YET FIXED):** `_cycle_orchestrator_run_body` reads `current_iter` unconditionally. Fix (step 6): wrap with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]`; fresh path sets `_start_iter=1`. Step 9: resume-loop-state-test.sh must export `_ZBUILD_RESUME_ACTIVE=true` before calling `cycle_orchestrator_run` directly.

**Finding 6 — SKIP-1 claim narrowed:** The complete-stage branch in the dispatch-unit `stage:*` arm is conditional: `continue` (skip) when artifact is present, `return 1` (exit 1) when artifact is absent. SKIP-1 covers the artifact-present path only. The absent-artifact case is explicitly covered by RHYD-2.

**Finding 7 — FRSH-1 changed to [no-code]:** Previous FRSH-1[done] had evidence at runner.sh line 2194 — that block sets up a fresh run_id and does not prove "no rehydration on fresh run." Changed to [no-code]: the test at resume-rehydrate-test.sh includes a --no-resume sub-case tagged [#1805/FRSH-1].

**Finding 8 — ADR amendment content:** AMDR-1 and AMDR-2 are [no-code] SPECs with tests in resume-rehydrate-test.sh that grep for the required amendment text in the ADR files. If the amendments are not written to the ADR files, those grep assertions fail.

**Finding 9 — FSTG-2 tautology fixed:** The assertion checks for "has no restorable primary artifact" — the phrase unique to `_runner_from_stage_preflight`, absent from old code.

**Finding 10 — SPECs expanded with Given/When/Then parts:** RHYD-1, RHYD-2, FSTG-1, FSTG-2, ITER-1, SKIP-1, ENTR-1, FRSH-2, and DLGT-1 have Given/When/Then sub-lines.

**Finding 11 — Then: lines made observable:** RHYD-1, FSTG-1, ENTR-1 Then lines state artifacts in ZBUILD_ARTIFACT_DIR and no stage.start events (not internal function names).

**Finding 12 — SKIP-1 and FRSH-2 Then/And lines made observable:** SKIP-1's Then: "No stage.start event is emitted for that stage." FRSH-2's Then: "Every stage emits a stage.start event."

**Finding 13 — DSPK-1 added:** RESU-3 and RESU-4 require "stage k is dispatched." SKIP-1 covers only skipping complete stages. DSPK-1[code] covers "stage k emits stage.start."

**Finding 14 — SPEC DISP-1 renamed to DSPK-1; LEGC-1 originally added:** The requirement code DISP-1 clashes with a SPEC named DISP-1. Renamed SPEC to DSPK-1. LEGC-1[done] was added to cover requirement DISP-1; subsequently replaced by SKIP-1[code] covers DISP-1 (Finding 18 below).

**Finding 15 — REMOVED tombstones:** REMOVED: DISP-1 (id collision) and REMOVED: BNDY-1 (described file contents) added to prevent id reuse.

**Finding 16 — Dispatch-unit path evidence (twenty-seventh pass correction):** Previous SKIP-1, FRSH-2, LEGC-1 cited `"When resuming, skip stages already marked complete unless --from-stage overrides"` (runner.sh:3895, legacy linear loop). After issue-acceptance finding 2 flagged DISP-1 violation, evidence was updated to `"ADR-006 §3.6 / #1805 (SPEC-1): resume mode — skip stages"` (runner.sh:3724, dispatch-unit path). The design checker then rejected this because that text was added by this branch.

**Finding 17 — ORDE-1 removed from requirements by intake:** ORDE-1 was a scheduling/process constraint ("do not run in parallel with another issue that edits the dispatch loop"). Intake classified it as a process note, not a code requirement, and removed it. AMDR-1's covers field previously included ORDE-1; it has been reduced to `covers: ADR-1` only. The ADR-006 amendment still records the ordering constraint as prose (a note about what not to run alongside), which is appropriate — the constraint belongs in the ADR, not in a testable SPEC.

**Finding 19 — AMDR-2 widened to cover §6 Enforced by citations (this pass):** Design finding 1 from the previous pass: AMDR-2 stated the boundary note but did not specify updating ADR-050 §6's "Enforced by" entry. The existing entry cites only `resume-default-test.sh R5–R11` for the new-run rule. AMDR-2's description now explicitly requires also adding citations for the new-run side (FRSH-2 / resume-rehydrate-test.sh) and the resume side (ENTR-1 / resume-entry-points-test.sh), satisfying CLAUDE.md's rule that every live ADR has an Enforced by section naming, per statement, the test that enforces it. Step 2 updated to match.

**Finding 20 — cycle member stage.start guard narrowed to resume-only (scope lens finding 1):** The diff adds `stage.start` emission at runner.sh:3166 for ALL cycle member dispatches at `iter > 0`, not just during resume. This is broader than DSPK-1 requires and changes the event contract for fresh cycle-based runs. The fix (Gap 7, step 7a): change the guard to `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]] && [[ "$_cd_iter" -gt 0 ]]; then`. `resume_mode` is a local variable and inaccessible inside `_cycle_dispatch`; `_ZBUILD_RESUME_ACTIVE` is exported and correctly scoped to resume runs. With the guard in place: resume runs emit stage.start for stage k (DSPK-1 satisfied), and fresh runs do not emit stage.start for cycle members (pre-branch event contract preserved). The cycle-member-dispatch-events-test.sh test checks `cycle.member.dispatch.start` (not `stage.start`), so it is unaffected; the existing DSPK-1 assertion in resume-rehydrate-test.sh checks for stage.start of "cycled" with `_ZBUILD_RESUME_ACTIVE=true` exported, so it still passes after the guard.

**Finding 21 — PATH-1 auto-resume state discovery gap (issue-acceptance finding):** The issue-acceptance stage flagged PATH-1 as unmet: the auto-resume check in runner.sh (line 2174) tests `[[ -f "$state_file" ]]` where `state_file = $state_dir/pipeline-state.json`. For the per-run default layout (ADR-059 §1), state is stored at `runs/<run_id>/pipeline-state.json`, not at the root; this flat path never exists, so auto-resume never fires without ZBUILD_STATE_FILE. The existing tests masked this by setting `ZBUILD_STATE_FILE="$P2_STATE_FILE"` explicitly — bypassing the discovery logic entirely. The `latest` symlink at `$(zbuild_layout_state_root)/latest` points to the most-recent per-run dir and is already used by `_find_state_file` in `scripts/zbuild`, but runner.sh never consults it. The fix (Gap 8, step 7b): inside the auto-resume elif, check `$state_dir/latest/pipeline-state.json` when the flat path is absent; update state_dir and state_file to the per-run dir when `auto_resume` fires via that path. ENTR-2[code] is added with a test that places state under `$state_root/runs/<run_id>/` WITHOUT ZBUILD_STATE_FILE set, verifying auto-resume fires. This test fails pre-change (no `latest` check → no auto-resume → no pipeline.resume event) and passes after the fix.

**Finding 18 — SKIP-1[code], FRSH-2[no-code], LEGC-1 REMOVED (this pass):**
- **SKIP-1**: The dispatch-unit skip-on-complete guards (runner.sh:3442, 3728) were added by this branch — no pre-change evidence exists in the dispatch-unit path. SKIP-1 must be [code]. Its test fails on pre-change code (no dispatch-unit skip guard → stage.start IS emitted for complete stages during resume in cyclic templates) and passes after (guard active). DISP-1 added to covers so LEGC-1 can be removed.
- **FRSH-2**: The dispatch-unit skip guard is conditioned on `$resume_mode` (false for fresh runs). Pre-change code had no dispatch-unit skip guard at all, so fresh runs never skipped — FRSH-2's test would pass on pre-change code too. Therefore [no-code]: the test need not fail before the change, only pass after (confirming the conditional guard works for fresh runs even with prior state present).
- **LEGC-1**: Was [done] with evidence from dispatch-unit code added by this branch. DISP-1 is now fully covered by SKIP-1[code], which tests the dispatch-unit behavior (not the legacy linear loop). LEGC-1 is redundant and REMOVED.
