# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed** — `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed** — exit 1 path at runner.sh:3920 (comment: "ADR-006 §3.6 (#1805): fail closed").
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed** — `_runner_from_stage_preflight` at runner.sh:1733.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, breaking nested loops. **NOT YET FIXED** — guard with `_ZBUILD_RESUME_ACTIVE` must still be added (step 6); runner.sh already exports `_ZBUILD_RESUME_ACTIVE=true` at line 2862. The test at resume-loop-state-test.sh must export it before calling `cycle_orchestrator_run` (step 9).
- Gap 5 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into `_artifact_persist_put_back <from> <to>` in `core/state/artifact-persist.sh`. Redirect hydrate's `hydrate_run` call site to the new function. At the resume entry point in runner.sh, export `_ZBUILD_RESUME_ACTIVE=true` (already at line 2862). In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi`. Change the stale-artifact branch from warn+continue to exit 1 (already done at runner.sh:3920). Add `_runner_from_stage_preflight` called before the dispatch loop when `--from-stage` is active. Amend ADR-006 and ADR-050.

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
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs) | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh (no-clobber copy skipping stage-io/); body identical to current _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh hydrate_run call site (line 162) to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: add [#1805/DLGT-1] section that overrides _artifact_persist_put_back with a sentinel-writing function, runs hydrate_run, and asserts the sentinel was written — fails when plugin reverted to inline _hydrate_put_back | areas: tests/unit/hydrate-stage-test.sh
- Fix _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: replace the unconditional current_iter block with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else local _start_iter=1; fi` — fresh runs and nested-loop re-entries always start at iter=1 | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, confirm `export _ZBUILD_RESUME_ACTIVE=true` is present immediately after the _runner_resume_rehydrate call (runner.sh:2862); do NOT set it for fresh runs | areas: core/pipeline/runner.sh
- Confirm tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, nested-loop-rounds-test.sh, nested-loop-rounds-build-test.sh, and cycle-member-dispatch-events-test.sh pass after the guard fix | areas: tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, tests/integration/cycle-member-dispatch-events-test.sh
- Update tests/integration/resume-loop-state-test.sh: add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the cycle_orchestrator_run call so the [#1805/ITER-1] assertion "first dispatched iter is 2" reaches the guard | areas: tests/integration/resume-loop-state-test.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix grep-c anti-pattern sites — replace with wc -l; (2) add --no-resume flag to the fresh-run sub-case; (3) remove stale cycled-dispatch assert_gt block; (4) retag the assert_contains type:cycle line to [#1805/CYCL-1]; (5) add [#1805/FRSH-1] assertion in the --no-resume sub-case verifying all stages dispatched from stage 1 with no stage.skip events emitted; (6) add [#1805/DSPK-1] assertion in the resume sub-case verifying stage k emits stage.start | areas: tests/integration/resume-rehydrate-test.sh
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
AMDR-1[no-code]: ADR-006-resume-contract.md amended with step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes); enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: ADR-1 ORDE-1
AMDR-2[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant "never skip a stage on prior output" applies to new runs; a resume continues the same run and is governed by ADR-006 covers: ADR-2
ITER-1[code]: Cycle orchestrator reads current_iter from persisted state on resume and starts the iteration loop from that value; fresh runs and nested-loop re-entries always start at iter=1 covers: LOOP-1
  Given: A run is being resumed; persisted state records cycle_iterations[CYCLE_ID].current_iter=2 (iter 1 completed before interruption); _ZBUILD_RESUME_ACTIVE=true is exported
  When: The cycle orchestrator's run body executes
  Then: The iteration loop starts at iter 2, not iter 1
  And: No stage.start event is emitted for any iter-1 stage
  And: When _ZBUILD_RESUME_ACTIVE is false or unset (fresh run or nested-loop re-entry), the loop starts at iter=1
SKIP-1[done]: On resume, the dispatch loop skips a complete stage whose primary artifact is present after rehydration covers: RESU-3 RESU-4 evidence: core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"
  Given: A run is being resumed; a stage is marked complete and its primary artifact is present in ZBUILD_ARTIFACT_DIR after rehydration
  When: The dispatch loop reaches that stage
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
FRSH-1[no-code]: A fresh run dispatches all stages from stage 1 with no stage skipped due to prior state and no prior-run artifacts in ZBUILD_ARTIFACT_DIR covers: GUAR-1
FRSH-2[done]: A new run of the same issue never skips a stage due to prior run output because the skip guard is conditional on resume_mode covers: GUAR-2 evidence: core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"
  Given: An issue has prior completed runs; a new run is started with no --resume flag and no status=interrupted state file
  When: The dispatch loop runs
  Then: Every stage emits a stage.start event and no stage.skip event is emitted for any stage
DLGT-1[code]: The hydrate plugin's hydrate_run calls _artifact_persist_put_back so artifacts placed by the resume path appear at the same filesystem paths as those a hydrate run would produce covers: HYDR-1
  Given: hydrate_run is about to execute; _artifact_persist_put_back is overridden in the test environment with a sentinel-writing function
  When: hydrate_run executes
  Then: The sentinel file is written, confirming hydrate_run reached _artifact_persist_put_back
CYCL-1[no-code]: The test fixtures used by resume-rehydrate-test.sh and from-stage-rehydrate-test.sh each contain a pipeline stage of type: cycle, verified by an assert_contains tagged [#1805/CYCL-1] in each file, ensuring RESU-1 through FROM-1 tests run against a cyclic pipeline covers: TEST-1
LEGC-1[done]: The dispatch-loop skip-on-complete guard exists in core/pipeline/runner.sh and is not grounded in legacy-DoNotUse dispatch code; this design's [done] SPECs cite evidence only from non-legacy source files covers: DISP-1 evidence: core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"
  When: The dispatch loop reaches a stage marked complete during resume
  Then: No stage.start event is emitted for that stage
REMOVED: DISP-1 — id collides with requirement code DISP-1 added by intake; the SPEC is preserved as DSPK-1
REMOVED: BNDY-1 — described file contents ("contains both…"), which no test can prove; ADR-2 is fully covered by AMDR-2; the two sides of the boundary are pinned by RHYD-1 (resume) and FRSH-1 (new-run)
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
ENTR-1: tests/integration/resume-entry-points-test.sh
FRSH-1: tests/integration/resume-rehydrate-test.sh
DLGT-1: tests/unit/hydrate-stage-test.sh
DSPK-1: tests/integration/resume-rehydrate-test.sh
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

**Finding 1 — All SPECs named:** RHYD-1/2 (resume hydration), FSTG-1/2 (from-stage), AMDR-1/2 (ADR amendments), ITER-1 (iteration state), SKIP-1 (skip-complete), DSPK-1 (dispatch interrupted stage k), ENTR-1 (entry points), FRSH-1/2 (fresh run), DLGT-1 (hydrate delegation), CYCL-1 (cycle fixture), LEGC-1 (legacy constraint). REMOVED: DISP-1 (id collision with requirement code), BNDY-1 (described file contents, not behaviour).

**Finding 2 — covers: fields use requirement IDs:** All SPECs name actual requirement IDs: RESU-1, RESU-2, RESU-3, RESU-4, FROM-1, FROM-2, FROM-3, LOOP-1, PATH-1, GUAR-1, GUAR-2, ADR-1, ADR-2, HYDR-1, TEST-1, ORDE-1, DISP-1.

**Finding 3 — All 17 requirements covered:** RESU-1: RHYD-1. RESU-2: RHYD-1, RHYD-2. RESU-3: SKIP-1, DSPK-1. RESU-4: RHYD-1, SKIP-1, DSPK-1. FROM-1: FSTG-1. FROM-2: FSTG-1. FROM-3: FSTG-2. LOOP-1: ITER-1. PATH-1: ENTR-1. GUAR-1: FRSH-1. GUAR-2: FRSH-2. ADR-1: AMDR-1. ADR-2: AMDR-2. HYDR-1: RHYD-1, DLGT-1. TEST-1: CYCL-1. ORDE-1: AMDR-1. DISP-1: LEGC-1.

**Finding 4 — Implementation state (verified):**
- `_artifact_persist_put_back` defined in artifact-persist.sh ✓
- `_artifact_persist_restore` defined in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- Stage k dispatch: skip guard at runner.sh:3896-3927 applies only when `stage_status == "complete"`; stage k (status not complete) falls through to `eb_emit_event "stage.start"` at runner.sh:3937 ✓

**Finding 5 — Cycle orchestrator guard (NOT YET FIXED):** `_cycle_orchestrator_run_body` reads `current_iter` unconditionally. Fix (step 6): wrap with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]`; fresh path sets `_start_iter=1`. Step 9: resume-loop-state-test.sh must export `_ZBUILD_RESUME_ACTIVE=true` before calling `cycle_orchestrator_run` directly.

**Finding 6 — SKIP-1 claim narrowed (prior pass):** The previous SKIP-1 said "skips any stage with stage_statuses[s]=='complete' during resume" — the checker found this overclaims because runner.sh:3899-3920 shows the complete-stage branch is conditional: `continue` (skip) when artifact is present, `return 1` (exit 1) when artifact is absent. The claim is now narrowed to the artifact-present path only. The absent-artifact case is explicitly covered by RHYD-2.

**Finding 7 — FRSH-1 changed to [no-code] (prior pass):** Previous FRSH-1[done] had evidence `runner.sh:"if ! $resume_mode; then"` (line 2194) — that block sets up a fresh run_id and does not prove "no rehydration on fresh run." Changed to [no-code]: the test at resume-rehydrate-test.sh includes a --no-resume sub-case tagged [#1805/FRSH-1] that asserts all stages were dispatched from stage 1 with no stage.skip events, which passes after the change and fails if the fresh-run guard were broken.

**Finding 8 — issue-acceptance findings 3/4 (ADR amendment content):** These findings report that the diff doesn't show ADR amendment content. This is a build-stage concern: the design correctly specifies AMDR-1 and AMDR-2 as [no-code] SPECs with tests in resume-rehydrate-test.sh that grep for the required amendment text in the ADR files. If the amendments are not written to the ADR files, those grep assertions fail. The design cannot show diff content it does not produce; the build stage implements the amendments and the test verifies them.

**Finding 9 — FSTG-2 tautology fixed (prior pass):** The assertion now checks for "has no restorable primary artifact" — the phrase unique to `_runner_from_stage_preflight`, absent from old code.

**Finding 10 — SPECs expanded with Given/When/Then parts (prior pass):** Previous design had 9 SPECs written on a single line without required sub-parts. That pass expanded RHYD-1, RHYD-2, FSTG-1, FSTG-2, ITER-1, SKIP-1, ENTR-1, FRSH-2, and DLGT-1 with their Given/When/Then/And sub-lines. AMDR-1, AMDR-2, FRSH-1, and CYCL-1 are [no-code] SPECs that describe structural/doc work and need no sub-parts.

**Finding 11 — Then: lines made observable (prior pass):** RHYD-1, FSTG-1, ENTR-1 Then lines rewrote internal function names into observable outputs (artifacts in ZBUILD_ARTIFACT_DIR, no stage.start events). SKIP-1 and FRSH-2 Then lines rewrote internal control-flow language into observable events.

**Finding 12 — SKIP-1 and FRSH-2 Then/And lines made observable (prior pass):** SKIP-1's Then: now says "No stage.start event is emitted for that stage." FRSH-2's And: "without consulting prior run state" (internal mechanism) removed.

**Finding 13 — DSPK-1 added (prior pass, renamed this pass):** RESU-3 and RESU-4 require "stage k is dispatched." SKIP-1 covers only skipping complete stages. Added DSPK-1[code]: "On resume, stage k (the interrupted stage) is dispatched and emits stage.start." Behavioral basis: runner.sh:3896-3927 (skip guard only for `stage_status == "complete"`); stage k falls through to `eb_emit_event "stage.start"` at runner.sh:3937.

**Finding 14 — SPEC DISP-1 renamed to DSPK-1; LEGC-1[done] added (prior pass):** The intake stage added a new requirement `DISP-1: No requirement may be marked done, and no change made, on the strength of the legacy loop.` This requirement code clashes with the SPEC I had named DISP-1. Rule: "A SPEC's code is never one of the issue's requirement codes." Renamed SPEC to DSPK-1 everywhere (acceptance block, step 10 tag, TESTFILES). Added LEGC-1[done] covers: DISP-1 to satisfy that requirement. LEGC-1 confirms that SKIP-1 and FRSH-2 — the two [done] SPECs — both cite evidence from `core/pipeline/runner.sh` (not `legacy-DoNotUse/`), so no [done] claim is grounded in the legacy dispatch loop. Evidence: `core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"` (runner.sh:3895).

**Finding 15 — REMOVED: DISP-1 tombstone + REMOVED: BNDY-1 tombstone (this pass):** The design checker flagged two issues: (a) DISP-1 disappeared without a tombstone — the rule requires `REMOVED: DISP-1 — <why>` to stay in every later design so the id is never reused; added. (b) BNDY-1 described file contents ("resume-rehydrate-test.sh contains both…"), which no test can prove. BNDY-1's intent was to pin both sides of the ADR-006/ADR-050 §6 boundary, but ADR-2 is fully covered by AMDR-2[no-code] (the amendment) and the two behavioural sides are already pinned by RHYD-1 (resume) and FRSH-1 (new-run). BNDY-1 is REMOVED; tombstone added. TESTFILES entry for BNDY-1 removed. Step 10 wording "BNDY-1 runner invocation" changed to "fresh-run sub-case". Finding 3 updated: ADR-2 → AMDR-2 only.
