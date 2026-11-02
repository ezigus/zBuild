# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed in implementation** — `_runner_resume_rehydrate` defined at runner.sh:1708 and called at runner.sh:2838.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed in implementation** — exit 1 at runner.sh:3827–3832.
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed in implementation** — `_runner_from_stage_preflight` at runner.sh:1727.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` from persisted state but **does so unconditionally**, breaking nested loops (inner cycle re-uses previous outer iteration's `current_iter`). **Still needs design fix** — see decision below.
- Gap 5 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into a new `_artifact_persist_put_back <from> <to>` function in `core/state/artifact-persist.sh` (which the runner already sources). Redirect the hydrate plugin's call site to the new function. At the single resume entry point in runner.sh (after `_zbuild_disarm_abort_sentinel`, at runner.sh:2838), call `_runner_resume_rehydrate`, which calls `_artifact_persist_restore` then `_artifact_persist_put_back`, then export `_ZBUILD_RESUME_ACTIVE=true` before the dispatch loop so cycle orchestrators know they are in resume context. Change the stale-artifact branch from warn+continue to exit 1. Add a `_runner_from_stage_preflight` function called before the dispatch loop when `--from-stage` is active, running the same restore+put_back sequence then verifying every pre-target stage's primary artifact is present. In `_cycle_orchestrator_run_body`, guard the `current_iter` restore with `[[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]` — only use persisted iter when actively resuming; otherwise start at 1. Amend ADR-006 and ADR-050 to document these decisions.

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
- Amend docs/adr/ADR-006-resume-contract.md: insert step 3.6 (rehydrate completed-stage artifacts; absent artifact after restore causes exit 1) and add enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) inline; step 3.5 covers cycle_iterations amendment — use 3.6 to avoid collision | areas: docs/adr/ADR-006-resume-contract.md
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs) | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh (no-clobber copy skipping stage-io/); body identical to current _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh _hydrate_put_back call site to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: redirect the direct _hydrate_put_back call at line 216 to _artifact_persist_put_back | areas: tests/unit/hydrate-stage-test.sh
- Fix _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: guard the current_iter read with [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; when not in resume mode, use _start_iter=1 unconditionally (restoring old behaviour for fresh runs and nested-loop re-entries) | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, after the _runner_resume_rehydrate call at the resume entry point, export _ZBUILD_RESUME_ACTIVE=true (before the dispatch loop) so cycle orchestrators know they are in resume context; do NOT set it for fresh runs | areas: core/pipeline/runner.sh
- Confirm tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, and tests/integration/cycle-member-dispatch-events-test.sh pass after the guard fix (they were broken by the unconditional current_iter read) | areas: tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, tests/integration/cycle-member-dispatch-events-test.sh
- Update tests/integration/resume-loop-state-test.sh: add export _ZBUILD_RESUME_ACTIVE=true before the cycle_orchestrator_run call (the test calls the orchestrator directly, bypassing runner.sh; without this the guard prevents reading current_iter and SPEC-7 "first dispatched iter is 2" fails); replace the "no iter=1 complete" zero-count assertion with wc -l | tr -d ' ' instead of grep -c || echo 0 (the latter produces "0\n0" when count=0) | areas: tests/integration/resume-loop-state-test.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix all three SPEC-1 zero-count assertions ("intake emits no stage.start") to use wc -l | tr -d ' ' instead of grep -c '^...$' 2>/dev/null || echo 0; (2) add --no-resume flag to the SPEC-12 runner invocation to prevent auto-resume (status=in_progress + recent timestamp triggers auto_resume); (3) remove the cycled-dispatch assertion for SPEC-12 (cycled does not dispatch in full runner runs) and replace with intake-dispatched + type:cycle fixture content check; (4) remove any [#1805/SPEC-13]-tagged assertions entirely — SPEC-13 is dropped | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: fix the SPEC-3 "intake emits no stage.start" zero-count assertion to use wc -l | tr -d ' ' instead of grep -c || echo 0 | areas: tests/integration/from-stage-rehydrate-test.sh
- Update tests/integration/resume-entry-points-test.sh: remove any [#1805/SPEC-13]-tagged cycled-dispatch assertion (SPEC-13 is dropped; no requirement mandates that cycled dispatches in full runner runs); the intake-dispatched assertion and type:cycle content check may remain if tagged under a valid SPEC or untagged | areas: tests/integration/resume-entry-points-test.sh
- Update tests/integration/pipeline-resume-test.sh: pre-write intake's primary artifact to ZBUILD_ARTIFACT_DIR before the --resume run so SPEC-2 fail-closed path does not break the existing exit-0 assertion | areas: tests/integration/pipeline-resume-test.sh
- Update tests/integration/resume-after-sigint-test.sh: ensure the Phase 1 intake stub writes intake-result.json; if the stub from mock_plugin_factory does not write it, replace with a stub that does; confirm P2.T1 (rc=0) still passes | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
SPEC-1[code]: On resume (all entry paths), before the dispatch loop, the runner calls _artifact_persist_restore and _artifact_persist_put_back and places completed-stage artifacts from the git state branch into ZBUILD_ARTIFACT_DIR; the complete stage emits no stage.start event covers: R-1 R-2 R-7
SPEC-2[code]: A complete stage whose primary artifact is absent from both disk and the git state branch causes the resume to exit 1 before any stage.start event is emitted covers: R-2 R-8
SPEC-3[code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore and _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and emits no stage.start for any earlier stage covers: R-4 R-10
SPEC-4[code]: --from-stage <s> when a stage before <s> has no restorable artifact exits 1 before dispatching anything and names the missing stage in stderr covers: R-11
SPEC-5[no-code]: ADR-006-resume-contract.md amended with step 3.6: before the dispatch loop the runner restores completed-stage artifacts from the git state branch; a still-absent artifact causes exit 1; enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: R-5
SPEC-6[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant applies to new runs; a resume continues the same run and is governed by ADR-006 covers: R-6
SPEC-7[code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter from persisted state at resume and starts the iteration loop from that value (not 1); iter-1 complete stages emit no stage.start on resume into iter-2; the guard uses _ZBUILD_RESUME_ACTIVE so fresh runs and nested-loop re-entries always start at iter=1 covers: R-9
SPEC-8[done]: The dispatch loop skips any stage with stage_statuses[s]=="complete" during resume, so the run picks up at the first non-complete stage covers: R-3 evidence: core/pipeline/runner.sh:3808
SPEC-9[code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting status=interrupted, zbuild pipeline resume --run-id) invoke _runner_resume_rehydrate before the dispatch loop covers: R-12
SPEC-10[done]: A run with no prior state file proceeds as a fresh start with no rehydration covers: R-13 evidence: core/state/resume.sh:247 core/pipeline/runner.sh:2824
SPEC-11[done]: A new run of the same issue never skips a stage because the stage-skip guard requires resume_mode=true, which is false for new runs covers: R-14 evidence: core/pipeline/runner.sh:3808
SPEC-12[no-code]: tests/integration/resume-rehydrate-test.sh contains a sub-case that runs a fresh (non-resume) run using the same cycle fixture, with --no-resume to prevent auto-resume, and verifies intake dispatches and the fixture contains type:cycle, pinning the new-run side of the ADR-050 §6 boundary covers: R-14
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
```

```supersedes
tests/integration/pipeline-resume-test.sh: sets stage_statuses["intake"]="complete" but never writes intake-result.json; after SPEC-2, missing artifact causes exit 1 instead of exit 0 — fix by pre-writing the artifact before the --resume run
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory may not write a primary artifact; after SPEC-2, a complete stage with no artifact causes exit 1, breaking P2.T1 (rc=0) — fix by ensuring the stub writes intake-result.json
tests/unit/hydrate-stage-test.sh: calls _hydrate_put_back directly at line 216; after the function is replaced by _artifact_persist_put_back in the plugin, this call must be updated to _artifact_persist_put_back
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard, inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: broken by unconditional current_iter read causing extra iterations and wrong verdict propagation; same fix restores correct behaviour
```

## Findings

**Finding 1 — SPEC-13 dropped (design checker findings 1 and 2):** SPEC-13 carried `covers: R-15`, but R-15 does not appear in the engine-numbered requirements R-1 through R-14. A SPEC that covers only a non-existent requirement is not valid. Separately, no listed requirement asks that every test file use a pipeline containing a cyclic stage; R-9 requires only that loop-resume iteration-state restore works correctly, which is addressed by SPEC-7 alone. SPEC-13 is therefore dropped. Steps 10 and 12 are updated: instead of changing SPEC-13 assertions to "intake dispatched via cyclic fixture", they now remove any `[#1805/SPEC-13]`-tagged assertions entirely.

**Finding 2 — SPEC-5 R-15 removed (design checker finding 3):** SPEC-5 previously carried `covers: R-5 R-15`. With R-15 non-existent, `R-15` is removed. SPEC-5 now covers only R-5 (amend ADR-006 with step 3.6 naming enforcing tests inline). R-5 coverage is complete on its own.

**Finding 3 — SPEC-8 and SPEC-11 evidence line numbers:** Evidence at `core/pipeline/runner.sh:3808` (`if $resume_mode && [[ -z "$skip_until_stage" ]]`) covers both. Confirmed valid.

**Finding 4 — SPEC-10 evidence line number:** `core/state/resume.sh:247` is inside `get_resume_recommendation`, the no-state-file → fresh_start branch. Confirmed valid.

**Finding 5 — _artifact_persist_put_back does not yet exist (expected):** Confirmed `_artifact_persist_restore` exists at artifact-persist.sh:568; `_artifact_persist_put_back` is new to add in the implementation step.

**Finding 6 — cycle orchestrator unconditional read (regression):** `_cycle_orchestrator_run_body` reads `current_iter` unconditionally, not guarded by resume mode. For nested loops, the inner cycle's `current_iter` persists from the first outer iteration, causing the second outer iteration to start the inner cycle at N+1 instead of 1. This broke four existing tests. Fix: guard with `${_ZBUILD_RESUME_ACTIVE:-false}` exported by runner.sh at resume entry; `resume-loop-state-test.sh` must also set `_ZBUILD_RESUME_ACTIVE=true` before its direct `cycle_orchestrator_run` call. The four tests are in scope and listed in supersedes (they pass again after the guard fix). SPEC-7 text includes the `_ZBUILD_RESUME_ACTIVE` guard requirement.

**Finding 7 — grep-c anti-pattern (zero-count failures):** `grep -c '^...$' 2>/dev/null || echo 0` produces `"0\n0"` when count=0 (grep outputs "0" then exits 1, `|| echo 0` fires adding another "0"). `assert_eq "0" "0\n0"` fails. Affects: SPEC-1 (three paths in resume-rehydrate-test.sh), SPEC-3 (from-stage-rehydrate-test.sh), SPEC-7 (resume-loop-state-test.sh). Fix: use `wc -l | tr -d ' '` in all zero-count assertions. Steps 9, 10, 11 updated accordingly.

**Finding 8 — SPEC-12 auto-resume and cycled dispatch:** `status: "in_progress"` + recent timestamp triggers `auto_resume` in `get_resume_recommendation`, making the "fresh run" sub-case actually a resume. Fix: add `--no-resume` to the SPEC-12 runner call. The `cycled` sub-stage does not dispatch in full runner runs of the `artifact-snapshot-coverage` fixture; the cycled-dispatch assertion fails. Fix: replace with intake-dispatched + type:cycle fixture content check. Deep cycle execution is verified by resume-loop-state-test.sh SPEC-7.
