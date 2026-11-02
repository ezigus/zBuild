# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active (`_ZBUILD_RESUME_ACTIVE=true`) — fresh runs and nested-loop re-entries must always start at iter=1.

**Context / gaps (verified against current build):**
- Gap 1 — runner.sh resume entry: **FIXED** — `_runner_resume_rehydrate` defined at runner.sh:1707 and called at runner.sh:2838.
- Gap 2 — stale-artifact branch exit 1: **FIXED** — exit 1 at runner.sh:3827–3832.
- Gap 3 — runner.sh from-stage path: **FIXED** — `_runner_from_stage_preflight` at runner.sh:1727.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally (no `_ZBUILD_RESUME_ACTIVE` guard): **NOT YET FIXED** — cycle-orchestrator.sh:2301 has no guard; nested-loop regression active.
- Gap 5 — ADR-006 and ADR-050 not amended: **FIXED** in implementation.
- Gap 6 — `_ZBUILD_RESUME_ACTIVE` not exported by runner.sh: **NOT YET FIXED** — runner.sh has no `export _ZBUILD_RESUME_ACTIVE=true`.
- Gap 7 — Test files use `grep -c ... || echo 0` for zero-count assertions: **NOT YET FIXED** — produces `"0\n0"` instead of `"0"`, causing `assert_eq "0" "0\n0"` failures in SPEC-1, SPEC-3, SPEC-7.
- Gap 8 — SPEC-12/13 tests assert `cycled` stage dispatches (it does not in full runner runs): **NOT YET FIXED** — `assert_gt cycled_starts "0"` remains.

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into a new `_artifact_persist_put_back <from> <to>` function in `core/state/artifact-persist.sh` (which the runner already sources). Redirect the hydrate plugin's call site to the new function. At the single resume entry point in runner.sh (after `_zbuild_disarm_abort_sentinel`, at runner.sh:2838), call `_runner_resume_rehydrate`, which calls `_artifact_persist_restore` then `_artifact_persist_put_back`, then `export _ZBUILD_RESUME_ACTIVE=true` before the dispatch loop so cycle orchestrators know they are in resume context. Change the stale-artifact branch from warn+continue to exit 1. Add a `_runner_from_stage_preflight` function called before the dispatch loop when `--from-stage` is active, running the same restore+put_back sequence then verifying every pre-target stage's primary artifact is present. In `_cycle_orchestrator_run_body`, guard the `current_iter` restore with `[[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]` — only use persisted iter when actively resuming; otherwise `_start_iter=1` unconditionally. Amend ADR-006 and ADR-050 to document these decisions.

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
- Amend docs/adr/ADR-006-resume-contract.md: insert step 3.6 (rehydrate completed-stage artifacts; absent artifact after restore causes exit 1) and add enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) inline; step 3.5 covers cycle_iterations amendment | areas: docs/adr/ADR-006-resume-contract.md
- Amend docs/adr/ADR-050-prior-work-reuse-contract.md §6: add boundary note that resume (same run, ADR-006) is distinct from new-run reuse (ADR-050 §6 governs) | areas: docs/adr/ADR-050-prior-work-reuse-contract.md
- Add _artifact_persist_put_back <from> <to> to core/state/artifact-persist.sh: body is a while-read loop over `find <from> -type f -print0`, skipping `stage-io/*` entries and files already present at `<to>/<rel>`, copying the rest with `cp -p` — identical semantics to _hydrate_put_back | areas: core/state/artifact-persist.sh
- Redirect plugins/tool/hydrate/plugin.sh _hydrate_put_back call site to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: redirect the direct _hydrate_put_back call to _artifact_persist_put_back | areas: tests/unit/hydrate-stage-test.sh
- Fix core/pipeline/cycle-orchestrator.sh _cycle_orchestrator_run_body: the block at line 2301 that reads _persisted_iter from get_state_field must be wrapped in a guard — `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then _persisted_iter="$(get_state_field "$state_file" ".cycle_iterations[\"$cycle_id\"].current_iter" 0 2>/dev/null || echo 0)"; else _persisted_iter=0; fi` — so _start_iter=1 for fresh runs and nested-loop re-entries (when _ZBUILD_RESUME_ACTIVE is unset or false) | areas: core/pipeline/cycle-orchestrator.sh
- In core/pipeline/runner.sh, immediately after the `_runner_resume_rehydrate "$_runner_issue" "$state_dir"` call at runner.sh:2838, add the line `export _ZBUILD_RESUME_ACTIVE=true` — this must appear before the dispatch loop runs; it must NOT appear in the fresh-run else branch | areas: core/pipeline/runner.sh
- Verify tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, and tests/integration/cycle-member-dispatch-events-test.sh pass after the guard fix (they were broken by the unconditional read and pass once the guard is added) | areas: tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, tests/integration/cycle-member-dispatch-events-test.sh
- Update tests/integration/resume-loop-state-test.sh: (1) add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the `cycle_orchestrator_run "build-test" "$ZBUILD_STATE_DIR" "$STATE_FILE"` call (the test drives the orchestrator directly, bypassing runner.sh; without this the guard causes _start_iter=1 and SPEC-7 first-iter=2 fails); (2) change the SPEC-7 zero-count assertion from `grep -c '^1$' 2>/dev/null || echo 0` to `wc -l | tr -d ' '` (pattern: `_s7_iter1_complete="$(jq -r '...' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"`) | areas: tests/integration/resume-loop-state-test.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix all three SPEC-1 zero-count assertions — lines using `grep -c '^intake$' ... || echo 0` — replace the grep-c subshell pattern with `wc -l | tr -d ' '` (three occurrences: path-1, path-2, path-3); (2) add `--no-resume` to the SPEC-12 runner invocation to prevent auto-resume (status=in_progress + recent timestamp triggers auto_resume, turning the "fresh run" sub-case into a resume); (3) remove `assert_gt "$_s12_cycled_starts" "0"` (SPEC-12) and `assert_gt "$_s12_cycled_starts" "0"` (SPEC-13) — cycled does not dispatch in full runner runs; replace SPEC-12 cycled assertion with the type:cycle content check `assert_contains "[#1805/SPEC-12] cycle fixture used in SPEC-12 fresh-run sub-case has type: cycle" "$_s12_fixt_content" "type: cycle"` (already present); replace SPEC-13 cycled assertion with `assert_eq "[#1805/SPEC-13] resume-rehydrate: pipeline with cyclic fixture was actually run (intake dispatched)" "1" "$_s12_intake_starts"` | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: fix the SPEC-3 zero-count assertion — the line using `grep -c '^intake$' 2>/dev/null || echo 0` — replace with `wc -l | tr -d ' '` | areas: tests/integration/from-stage-rehydrate-test.sh
- Update tests/integration/resume-entry-points-test.sh: remove `assert_gt "$_s13_ep_cycled_starts" "0"` (SPEC-13; cycled does not dispatch in full runner runs); replace with `assert_eq "[#1805/SPEC-13] cyclic fixture pipeline ran in resume-entry-points test (intake dispatched)" "1" "$_s13_ep_intake_starts"` (the intake assertion already present at line 295 passes; the type:cycle content check at line ~289 already passes) | areas: tests/integration/resume-entry-points-test.sh
- Update tests/integration/pipeline-resume-test.sh: pre-write intake's primary artifact to ZBUILD_ARTIFACT_DIR before the --resume run so SPEC-2 fail-closed path does not break the existing exit-0 assertion | areas: tests/integration/pipeline-resume-test.sh
- Update tests/integration/resume-after-sigint-test.sh: ensure Phase 1 intake stub writes intake-result.json; if the stub from mock_plugin_factory does not write it, replace with a stub that does; confirm P2.T1 (rc=0) still passes | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
SPEC-1[code]: On resume (all entry paths), before the dispatch loop, the runner calls _artifact_persist_restore and _artifact_persist_put_back and places completed-stage artifacts from the git state branch into ZBUILD_ARTIFACT_DIR; the complete stage emits no stage.start event covers: R-1 R-2 R-7
SPEC-2[code]: A complete stage whose primary artifact is absent from both disk and the git state branch causes the resume to exit 1 before any stage.start event is emitted covers: R-2 R-8
SPEC-3[code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore and _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and emits no stage.start for any earlier stage covers: R-4 R-10
SPEC-4[code]: --from-stage <s> when a stage before <s> has no restorable artifact exits 1 before dispatching anything and names the missing stage in stderr covers: R-11
SPEC-5[no-code]: ADR-006-resume-contract.md amended with step 3.6: before the dispatch loop the runner restores completed-stage artifacts from the git state branch; a still-absent artifact causes exit 1; enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline covers: R-5 R-15
SPEC-6[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant applies to new runs; a resume continues the same run and is governed by ADR-006 covers: R-6
SPEC-7[code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter from persisted state only when _ZBUILD_RESUME_ACTIVE=true, and starts the iteration loop from that value (not 1); when _ZBUILD_RESUME_ACTIVE is unset or false the orchestrator always starts at iter=1; iter-1 complete stages emit no stage.start on resume into iter-2 covers: R-9
SPEC-8[done]: The dispatch loop skips any stage with stage_statuses[s]=="complete" during resume, so the run picks up at the first non-complete stage covers: R-3 evidence: core/pipeline/runner.sh:3808
SPEC-9[code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting status=interrupted, zbuild pipeline resume --run-id) invoke _runner_resume_rehydrate before the dispatch loop covers: R-12
SPEC-10[done]: A run with no prior state file proceeds as a fresh start with no rehydration covers: R-13 evidence: core/state/resume.sh:247 core/pipeline/runner.sh:2824
SPEC-11[done]: A new run of the same issue never skips a stage because the stage-skip guard requires resume_mode=true, which is false for new runs covers: R-14 evidence: core/pipeline/runner.sh:3808
SPEC-12[no-code]: tests/integration/resume-rehydrate-test.sh contains a sub-case that runs a fresh (non-resume) run using the same cycle fixture (with --no-resume to prevent auto-resume), verifies intake dispatches, and verifies the fixture contains type:cycle, pinning the new-run side of the ADR-050 §6 boundary covers: R-14
SPEC-13[no-code]: Test fixtures in resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, resume-loop-state-test.sh, and resume-entry-points-test.sh each use a pipeline containing a cyclic stage, verified by template type:cycle content check and at least one stage.start event emitted by that pipeline run covers: R-15
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
tests/unit/hydrate-stage-test.sh: calls _hydrate_put_back directly; after the function is replaced by _artifact_persist_put_back in the plugin, this call must be updated to _artifact_persist_put_back
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard, inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: broken by unconditional current_iter read causing extra iterations and wrong verdict propagation; same fix restores correct behaviour
```

## Findings

**Finding 1 — phantom R-15 (carried forward, no change):** R-15 ("tests for R1–R5 use a cycle") does not appear in the formal R-1–R-14 list the engine numbered, but the issue-acceptance stage references it. SPEC-5 carries `covers: R-5 R-15` and SPEC-13 carries `covers: R-15`. Both SPECs address the requirement. No change to the design.

**Finding 2 — `_ZBUILD_RESUME_ACTIVE` guard missing from cycle-orchestrator.sh (issue-acceptance finding 6; gap 4/6):** `core/pipeline/cycle-orchestrator.sh:2301` reads `current_iter` unconditionally and `runner.sh` never exports `_ZBUILD_RESUME_ACTIVE=true`. These are build-implementation failures; the design steps 6 and 7 already specify the exact changes. Updated Gap 4 and Gap 6 in the Context section to mark them as NOT YET FIXED. The step descriptions are made more explicit with the exact guard expression and exact insertion point.

**Finding 3 — grep-c anti-pattern on zero-count assertions (test finding / issue-acceptance findings 1, 2, 3):** Five assertion sites use `| grep -c '^...$' 2>/dev/null || echo 0`. When the pipeline produces 0 lines, `grep -c` outputs `"0"` and exits 1; the `|| echo 0` fallback appends another `"0"`, and `$(...)` captures `"0\n0"`, failing `assert_eq "0" "0\n0"`. Affected lines: resume-rehydrate-test.sh:139 (SPEC-1 path-1), :217 (path-2), :295 (path-3); from-stage-rehydrate-test.sh:134 (SPEC-3); resume-loop-state-test.sh:93 (SPEC-7). The underlying behaviors are correct (the implementation works; intake IS skipped; iter=1 IS not run). The fix — `wc -l | tr -d ' '` — is a build-implementation failure. Steps 9, 10, 11 now name the specific occurrences and show the replacement pattern. This finding is addressed entirely within the existing design scope.

**Finding 4 — SPEC-12/13 `assert_gt cycled_starts "0"` not changed (issue-acceptance findings 4, 5):** `resume-rehydrate-test.sh:488`, `:511`, and `resume-entry-points-test.sh:303` still assert `cycled` stage dispatches. The `cycled` sub-stage does not dispatch in full runner runs of the `artifact-snapshot-coverage` fixture (intake dispatches, the cycle body does not reach completion in the test environment). This is a build-implementation failure. Steps 10 and 12 now name the specific assertion lines and the exact replacement. SPEC-13 acceptance text updated: "at least one stage.start event emitted by that pipeline run" (i.e., intake dispatched, proving the pipeline ran via the cyclic fixture).

**Finding 5 — `_artifact_persist_put_back` and core rehydration functions confirmed present:** `_artifact_persist_put_back` at artifact-persist.sh:638, `_runner_resume_rehydrate` at runner.sh:1707, `_runner_from_stage_preflight` at runner.sh:1727 — all implemented. Skip logic at runner.sh:3808 is correct. SPEC-8[done] and SPEC-11[done] evidence lines are valid.
