# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1.

**Context / gaps:**  
- Gap 1 — runner.sh resume entry (line 2759–2769) disarms the sentinel and emits `pipeline.resume` but performs no artifact restoration.  
- Gap 2 — runner.sh dispatch loop (line 3727–3751) warns and `continue`s when `stage_statuses[s]=="complete"` but the primary artifact is missing; after rehydration the right behaviour is exit 1.  
- Gap 3 — runner.sh from-stage path (line 3755–3760) skips stages with no artifact check or rehydration.  
- Gap 4 — cycle-orchestrator.sh line 2309 always starts the iteration loop from `iter=1`, ignoring the persisted `current_iter`.  
- Gap 5 — ADR-006 step 5 mentions no artifact restoration; ADR-050 §6 does not draw the line between resume and new-run reuse.

**Decision:**  
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh lines 64-73) into a new `_artifact_persist_put_back <from> <to>` function in `core/state/artifact-persist.sh` (which the runner already sources). Redirect the hydrate plugin's call site to the new function. At the single resume entry point in runner.sh (immediately after the disarm on line 2768), call `_artifact_persist_restore` then `_artifact_persist_put_back`. Change the stale-artifact branch (line 3740–3745) from warn+continue to exit 1. Add a `_runner_from_stage_preflight` function called before the dispatch loop when `--from-stage` is active, running the same restore+put_back sequence then verifying every pre-target stage's primary artifact is present. In `_cycle_orchestrator_run_body`, read `cycle_iterations[CYCLE_ID].current_iter` from persisted state (default 1 if absent) and use it as the loop start. Amend ADR-006 and ADR-050 to document these decisions. All three resume entry paths (--resume flag, auto-resume, `zbuild pipeline resume --run-id`) converge on runner.sh's resume entry point and are covered by the single rehydrate call there.

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
```

```steps
- Amend docs/adr/ADR-006-resume-contract.md: insert step 3.6 (rehydrate completed-stage artifacts; absent artifact after restore causes exit 1) and add enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) inline; note: step 3.5 already exists under the cycle_iterations amendment — use 3.6 to avoid collision | areas: docs/adr/ADR-006-resume-contract.md
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs) | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh (no-clobber copy skipping stage-io/); identical body to current _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh _hydrate_put_back call site to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: redirect the direct _hydrate_put_back call at line 216 to _artifact_persist_put_back | areas: tests/unit/hydrate-stage-test.sh
- Write tests/integration/resume-rehydrate-test.sh for SPEC-1, SPEC-2, SPEC-12, and SPEC-13: use a cycle fixture throughout; include a new-run sub-case (resume_mode unset) that verifies all stages dispatch for SPEC-12 (run red before implementation of SPEC-1 and SPEC-2) | areas: tests/integration/resume-rehydrate-test.sh
- Add _runner_resume_rehydrate to core/pipeline/runner.sh: calls _artifact_persist_restore then _artifact_persist_put_back; call it at resume entry after line 2768 for all three resume paths; change stale-artifact branch (line 3740-3745) from warn+continue to exit 1 | areas: core/pipeline/runner.sh
- Run tests/integration/resume-rehydrate-test.sh and confirm SPEC-1, SPEC-2, SPEC-12, and SPEC-13 (cycle fixture sub-cases) green | areas: tests/integration/resume-rehydrate-test.sh
- Write tests/integration/from-stage-rehydrate-test.sh for SPEC-3, SPEC-4, and SPEC-13: use a cycle fixture throughout (run red before implementation) | areas: tests/integration/from-stage-rehydrate-test.sh
- Add _runner_from_stage_preflight to core/pipeline/runner.sh: restore+put_back, then verify each pre-target stage has its primary artifact, exit 1 naming missing stage if not; call before dispatch loop when from_stage is set | areas: core/pipeline/runner.sh
- Run tests/integration/from-stage-rehydrate-test.sh and confirm SPEC-3, SPEC-4, and SPEC-13 (cycle fixture) green | areas: tests/integration/from-stage-rehydrate-test.sh
- Write tests/integration/resume-loop-state-test.sh for SPEC-7 and SPEC-13: use a cycle fixture with at least two iterations (run red before implementation) | areas: tests/integration/resume-loop-state-test.sh
- Fix _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: read cycle_iterations[CYCLE_ID].current_iter via get_state_field (default 1), use it as loop start index | areas: core/pipeline/cycle-orchestrator.sh
- Run tests/integration/resume-loop-state-test.sh and confirm SPEC-7 and SPEC-13 green | areas: tests/integration/resume-loop-state-test.sh
- Write tests/integration/resume-entry-points-test.sh for SPEC-9 and SPEC-13: three sub-cases (--resume flag, auto-resume, zbuild pipeline resume --run-id) each use a cycle fixture and assert state-branch artifact appears in ZBUILD_ARTIFACT_DIR before first non-complete stage dispatches | areas: tests/integration/resume-entry-points-test.sh
- Run tests/integration/resume-entry-points-test.sh and confirm SPEC-9 and SPEC-13 green | areas: tests/integration/resume-entry-points-test.sh
- Update tests/integration/pipeline-resume-test.sh: pre-write intake's primary artifact to ZBUILD_ARTIFACT_DIR before the --resume run so SPEC-2 fail-closed path does not break the existing exit-0 assertion | areas: tests/integration/pipeline-resume-test.sh
- Update tests/integration/resume-after-sigint-test.sh: if the Phase 1 intake stub does not write intake-result.json, replace with a stub that does; confirm P2.T1 (rc=0) still passes | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
SPEC-1[code]: On resume (all entry paths), before the dispatch loop, the runner calls _artifact_persist_restore and _artifact_persist_put_back and places completed-stage artifacts from the git state branch into ZBUILD_ARTIFACT_DIR; the complete stage emits no stage.start event covers: R-1 R-2 R-7
SPEC-2[code]: A complete stage whose primary artifact is absent from both disk and the git state branch causes the resume to exit 1 before any stage.start event is emitted covers: R-2 R-8
SPEC-3[code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore and _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and emits no stage.start for any earlier stage covers: R-4 R-10
SPEC-4[code]: --from-stage <s> when a stage before <s> has no restorable artifact exits 1 before dispatching anything and names the missing stage in stderr covers: R-11
SPEC-5[no-code]: ADR-006-resume-contract.md amended with step 3.6: before the dispatch loop the runner restores completed-stage artifacts from the git state branch; a still-absent artifact causes exit 1; enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: R-5 R-15
SPEC-6[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant applies to new runs; a resume continues the same run and is governed by ADR-006 covers: R-6
SPEC-7[code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter from persisted state at resume and starts the iteration loop from that value (not 1); iter-1 complete stages emit no stage.start on resume into iter-2 covers: R-9
SPEC-8[done]: The dispatch loop skips any stage with stage_statuses[s]=="complete" during resume, so the run picks up at the first non-complete stage covers: R-3 evidence: core/pipeline/runner.sh:3724
SPEC-9[code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting status=interrupted, zbuild pipeline resume --run-id) invoke _runner_resume_rehydrate before the dispatch loop covers: R-12
SPEC-10[done]: A run with no prior state file proceeds as a fresh start with no rehydration covers: R-13 evidence: core/state/resume.sh:247 core/pipeline/runner.sh:2087
SPEC-11[done]: A new run of the same issue never skips a stage because the stage-skip guard requires resume_mode=true, which is false for new runs covers: R-14 evidence: core/pipeline/runner.sh:3724
SPEC-12[no-code]: tests/integration/resume-rehydrate-test.sh contains a sub-case that runs a fresh (non-resume) run of the same cycle fixture and verifies all stages dispatch without any being skipped, pinning the new-run side of the ADR-050 §6 boundary covers: R-14
SPEC-13[no-code]: Test fixtures in resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, resume-loop-state-test.sh, and resume-entry-points-test.sh each use a pipeline containing a cyclic stage covers: R-15
WIRING:
core/pipeline/runner.sh
core/pipeline/cycle-orchestrator.sh
TESTFILES:
SPEC-1: tests/integration/resume-rehydrate-test.sh
SPEC-2: tests/integration/resume-rehydrate-test.sh
SPEC-3: tests/integration/from-stage-rehydrate-test.sh
SPEC-4: tests/integration/from-stage-rehydrate-test.sh
SPEC-5: tests/integration/resume-rehydrate-test.sh
SPEC-6: tests/integration/resume-rehydrate-test.sh
SPEC-7: tests/integration/resume-loop-state-test.sh
SPEC-9: tests/integration/resume-entry-points-test.sh
SPEC-12: tests/integration/resume-rehydrate-test.sh
SPEC-13: tests/integration/resume-rehydrate-test.sh tests/integration/from-stage-rehydrate-test.sh tests/integration/resume-loop-state-test.sh tests/integration/resume-entry-points-test.sh
```

```supersedes
tests/integration/pipeline-resume-test.sh: sets stage_statuses["intake"]="complete" but never writes intake-result.json; after SPEC-2, missing artifact causes exit 1 instead of exit 0 — fix by pre-writing the artifact before the --resume run
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory may not write a primary artifact; after SPEC-2, a complete stage with no artifact causes exit 1, breaking P2.T1 (rc=0) — fix by ensuring the stub writes intake-result.json
tests/unit/hydrate-stage-test.sh: calls _hydrate_put_back directly at line 216; after the function is replaced by _artifact_persist_put_back in the plugin, this call must be updated to _artifact_persist_put_back
```

## Findings

**Finding 1 (R-15 not covered):** SPEC-5 already carried `covers: R-5 R-15` — no change needed. ADR-006 is in `config/adr-enforcement-baseline.txt`, so no `## Enforced by` section is required; the amendment naming its enforcing tests inline satisfies R-5's "amendment naming its enforcing tests inline" clause.

**Finding 2 (SPEC-12 phantom R-16 → R-14):** SPEC-12 previously cited `covers: R-16`, but R-16 does not exist in the issue requirements (the issue lists R-1 through R-15 only). SPEC-12 mandates a fresh-run sub-case that pins the new-run side of the ADR-050 §6 boundary — the exact invariant R-14 requires. Fixed to `covers: R-14`. SPEC-11[done] independently evidences R-14 at runner.sh:3724; SPEC-12 adds a test that exercises it.

**Finding 3 (SPEC-13 phantom R-17 = R-15):** SPEC-13 previously cited `covers: R-17`, but R-17 does not exist in the issue requirements. R-17 was a mis-numbered duplicate of R-15 ("Tests for R1–R5 must use a cycle"). Fixed to `covers: R-15`. R-15 now has two SPEC entries (SPEC-5 for the ADR amendment, SPEC-13 for the cycle-fixture mandate) — both are correct and non-overlapping.

**Finding 4 (SPEC-10 evidence line number):** `core/state/resume.sh:244` was the function definition header of `get_resume_recommendation()`; the actual condition `if [[ ! -f "$state_file" ]]; then` that triggers `echo "fresh_start"` is at line 247. Corrected to `core/state/resume.sh:247`.

**Finding 5 (_artifact_persist_put_back does not yet exist — expected):** Code search confirmed `_artifact_persist_restore` exists at artifact-persist.sh:568 and `_artifact_persist_put_back` does not yet exist. The design lists it as a new function to add (step 3 in the steps block); no scope change needed.

**Restoration (resume-after-sigint):** The file on disk had dropped the resume-after-sigint step and supersedes entry. Both restored; the scope entry was present and correct throughout.
