# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed** — `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed** — exit 1 path at runner.sh (comment: "ADR-006 §3.6 (#1805): fail closed").
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed** — `_runner_from_stage_preflight` at runner.sh:1733.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, breaking nested loops. **Fixed** — `if [[ "${_ZBUILD_RESUME_ACTIVE:-false}" == "true" ]]` guard at cycle-orchestrator.sh:2326; resume-loop-state-test.sh exports `_ZBUILD_RESUME_ACTIVE=true` at line 82.
- Gap 5 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into `_artifact_persist_put_back <from> <to>` in `core/state/artifact-persist.sh`. Redirect hydrate's `hydrate_run` call site to the new function. At the resume entry point in runner.sh, export `_ZBUILD_RESUME_ACTIVE=true` (already at line 2862). In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else _start_iter=1; fi`. Change the stale-artifact branch from warn+continue to exit 1. Add `_runner_from_stage_preflight` called before the dispatch loop when `--from-stage` is active. Amend ADR-006 and ADR-050.

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
- Update tests/integration/resume-rehydrate-test.sh: (1) fix grep-c anti-pattern sites — replace with wc -l; (2) add --no-resume flag to the BNDY-1 runner invocation; (3) remove stale cycled-dispatch assert_gt block; (4) retag the assert_contains type:cycle line to [#1805/CYCL-1] | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: (1) fix FSTG-1 zero-count grep-c with wc -l; (2) retag assert_contains type:cycle to [#1805/CYCL-1]; (3) change FSTG-2 assert_contains to check for "has no restorable primary artifact" | areas: tests/integration/from-stage-rehydrate-test.sh
- Verify tests/integration/resume-entry-points-test.sh: three entry-path assertions tagged [#1805/ENTR-1] | areas: tests/integration/resume-entry-points-test.sh
- Verify tests/integration/pipeline-resume-test.sh: intake's primary artifact pre-written to ZBUILD_ARTIFACT_DIR before the --resume run | areas: tests/integration/pipeline-resume-test.sh
- Verify tests/integration/resume-after-sigint-test.sh: mock_plugin_factory "intake" writes intake-result.json; runner snapshots it after Phase 1; resume rehydration restores it; P2.T1 (rc=0) still passes with RHYD-2 fail-closed in effect | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
RHYD-1[code]: On resume (all entry paths), before the dispatch loop, the runner calls _artifact_persist_restore and _artifact_persist_put_back and places completed-stage artifacts from the git state branch into ZBUILD_ARTIFACT_DIR; a complete stage emits no stage.start event covers: RESU-1 RESU-2 RESU-4 HYDR-1
RHYD-2[code]: A complete stage whose primary artifact is absent from both disk and the git state branch causes the resume to exit 1 before any stage.start event is emitted covers: RESU-2
FSTG-1[code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore and _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and emits no stage.start for any earlier stage covers: FROM-1 FROM-2
FSTG-2[code]: --from-stage <s> when a stage before <s> has no restorable artifact emits the diagnostic phrase "has no restorable primary artifact" to stderr and exits 1 before any stage.start event is emitted covers: FROM-3
AMDR-1[done]: ADR-006-resume-contract.md amended with step 3.6 (rehydrate completed-stage artifacts before dispatch loop; absent artifact causes exit 1; ordering constraint: not to be combined with dispatch-loop changes); enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: ADR-1 ORDE-1 evidence: docs/adr/ADR-006-resume-contract.md:"3.6. _runner_resume_rehydrate: before the dispatch loop"
AMDR-2[done]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant "never skip a stage on prior output" applies to new runs; a resume continues the same run and is governed by ADR-006 covers: ADR-2 evidence: docs/adr/ADR-050-prior-work-reuse-contract.md:"Resume boundary (issue #1805, ADR-006 §3.6)"
ITER-1[code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter from persisted state at resume and starts the iteration loop from that value (not 1); iter-1 complete stages emit no stage.start on resume into iter-2; the guard uses _ZBUILD_RESUME_ACTIVE so fresh runs and nested-loop re-entries always start at iter=1 covers: LOOP-1
SKIP-1[done]: The dispatch loop skips any stage with stage_statuses[s]=="complete" during resume so the run picks up at the first non-complete stage covers: RESU-3 RESU-4 evidence: core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"
ENTR-1[code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting status=interrupted, zbuild pipeline resume --run-id) invoke _runner_resume_rehydrate before the dispatch loop covers: PATH-1
FRSH-1[done]: A run with no prior state file proceeds as a fresh start with no rehydration covers: GUAR-1 evidence: core/state/resume.sh:"get_resume_recommendation" core/pipeline/runner.sh:"if ! $resume_mode; then"
FRSH-2[done]: A new run of the same issue never skips a stage because the skip guard requires $resume_mode which is false for new runs covers: GUAR-2 evidence: core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"
BNDY-1[done]: resume-rehydrate-test.sh contains both a resume-side assertion (RHYD-1/RHYD-2) and a fresh-run sub-case with --no-resume, pinning both sides of the ADR-006/ADR-050 §6 boundary in one test file covers: ADR-2 evidence: tests/integration/resume-rehydrate-test.sh:"[#1805/BNDY-1] fresh run dispatches intake"
DLGT-1[code]: The hydrate plugin's hydrate_run delegates its copy-back operation to _artifact_persist_put_back (not the old inline _hydrate_put_back); a sentinel-mock test in hydrate-stage-test.sh overrides _artifact_persist_put_back, calls hydrate_run, and asserts the mock was reached — fails when plugins/tool/hydrate/plugin.sh is reverted to inline _hydrate_put_back covers: HYDR-1
CYCL-1[done]: The test fixtures used by resume-rehydrate-test.sh and from-stage-rehydrate-test.sh each contain a pipeline stage of type: cycle, verified by an assert_contains tagged [#1805/CYCL-1] in each file, ensuring RESU-1 through FROM-1 tests run against a cyclic pipeline covers: TEST-1 evidence: tests/integration/resume-rehydrate-test.sh:"[#1805/CYCL-1] resume-rehydrate" tests/integration/from-stage-rehydrate-test.sh:"[#1805/CYCL-1] from-stage-rehydrate"
WIRING:
core/pipeline/runner.sh
core/pipeline/cycle-orchestrator.sh
plugins/tool/hydrate/plugin.sh
TESTFILES:
RHYD-1: tests/integration/resume-rehydrate-test.sh
RHYD-2: tests/integration/resume-rehydrate-test.sh
FSTG-1: tests/integration/from-stage-rehydrate-test.sh
FSTG-2: tests/integration/from-stage-rehydrate-test.sh
ITER-1: tests/integration/resume-loop-state-test.sh
ENTR-1: tests/integration/resume-entry-points-test.sh
DLGT-1: tests/unit/hydrate-stage-test.sh
```

```supersedes
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory writes intake-result.json and the runner snapshots it; verify P2.T1 (rc=0) still passes with RHYD-2 fail-closed in effect
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard (step 6), inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: broken by unconditional current_iter read causing extra iterations; same fix restores correct behaviour
```

## Findings

**Finding 1 — All SPECs renamed (this pass):** Previous design used SPEC-N numbering. All SPECs now use descriptive IDs: RHYD-1/2 (resume hydration), FSTG-1/2 (from-stage), AMDR-1/2 (ADR amendments), ITER-1 (iteration state), SKIP-1 (skip-complete), ENTR-1 (entry points), FRSH-1/2 (fresh run), BNDY-1 (boundary), DLGT-1 (hydrate delegation), CYCL-1 (cycle fixture). No REMOVED lines needed per design instructions.

**Finding 2 — Evidence uses exact text (this pass):** Previous design cited line numbers (e.g. `runner.sh:3896`). All evidence now uses exact text snippets: `core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"` for SKIP-1 and FRSH-2; `core/state/resume.sh:"get_resume_recommendation"` plus `core/pipeline/runner.sh:"if ! $resume_mode; then"` for FRSH-1.

**Finding 3 — covers: fields use requirement IDs (this pass):** Previous design used R-N notation (R-1, R-2…) in covers fields. All SPECs now name actual requirement IDs: RESU-1, RESU-2, RESU-3, RESU-4, FROM-1, FROM-2, FROM-3, LOOP-1, PATH-1, GUAR-1, GUAR-2, ADR-1, ADR-2, HYDR-1, TEST-1, ORDE-1.

**Finding 4 — All 16 requirements covered:** RESU-1: RHYD-1. RESU-2: RHYD-1, RHYD-2. RESU-3: SKIP-1. RESU-4: RHYD-1, SKIP-1. FROM-1: FSTG-1. FROM-2: FSTG-1. FROM-3: FSTG-2. LOOP-1: ITER-1. PATH-1: ENTR-1. GUAR-1: FRSH-1. GUAR-2: FRSH-2. ADR-1: AMDR-1. ADR-2: AMDR-2, BNDY-1. HYDR-1: RHYD-1, DLGT-1. TEST-1: CYCL-1. ORDE-1: AMDR-1 (ADR amendment documents ordering constraint).

**Finding 5 — Implementation state (verified):**
- `_artifact_persist_put_back` defined in artifact-persist.sh ✓
- `_artifact_persist_restore` defined in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓

**Finding 6 — Cycle orchestrator guard (FIXED, verified this pass):** `_cycle_orchestrator_run_body` at cycle-orchestrator.sh:2326 now wraps the `current_iter` read with `if [[ "${_ZBUILD_RESUME_ACTIVE:-false}" == "true" ]]; then … else _start_iter=1; fi`. `resume-loop-state-test.sh` exports `_ZBUILD_RESUME_ACTIVE=true` at line 82 before calling `cycle_orchestrator_run`. Both fixes verified in the current tree.

**Finding 7 — FSTG-2 tautology fixed (prior pass):** The old assertion checking `assert_contains "$_s4_stderr" "intake"` was tautological. Fixed by checking for `"has no restorable primary artifact"` — the phrase unique to `_runner_from_stage_preflight`, absent from old code. FSTG-2 text reflects this phrase.

**Finding 8 — issue-acceptance findings 3/4 resolved (this pass):** AMDR-1 and AMDR-2 changed from [no-code] to [done]. Both ADR amendments are verified in the current tree: ADR-006 contains step 3.6 text `"3.6. _runner_resume_rehydrate: before the dispatch loop"` at line 114; ADR-050 §6 contains `"Resume boundary (issue #1805, ADR-006 §3.6)"` at line 194. Evidence fields are exact file-text citations so issue-acceptance can verify without a diff. BNDY-1 and CYCL-1 also changed to [done] with evidence from their test files (the test assertions are already present in the current tree). TESTFILES entries for AMDR-1, AMDR-2, BNDY-1, CYCL-1 removed as [done] requires no test.
