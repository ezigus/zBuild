# Design: #1805 — resume and --from-stage trust-and-rehydrate

## Architectural decision

**Goal:** When a run is resumed (via `--resume`, auto-resume, or `zbuild pipeline resume --run-id`), every stage already marked `complete` in the persisted state must have its artifacts restored from the git state branch into `ZBUILD_ARTIFACT_DIR` before the dispatch loop runs, using the same extraction path the hydrate plugin uses. After that restoration, a `complete` stage whose primary artifact is still absent must exit 1 (fail closed). For `--from-stage <s>`, the same rehydration runs for every stage before `<s>`; if any pre-target stage has no restorable artifact, the runner refuses before dispatching anything. Inside a loop, the cycle orchestrator must restore `cycle_iterations[X].current_iter` from persisted state and begin the iteration loop from that value, not from 1, but ONLY when a resume is active — fresh runs must always start from iter=1.

**Context / gaps (verified against current tree):**
- Gap 1 — runner.sh resume entry: disarms sentinel, emits `pipeline.resume`, NO artifact restoration. **Fixed in implementation** — `_runner_resume_rehydrate` defined at runner.sh:1702 and called at runner.sh:2838.
- Gap 2 — runner.sh stale-artifact branch warned+continued; after rehydration the right behaviour is exit 1. **Fixed in implementation** — exit 1 at runner.sh:3827–3832.
- Gap 3 — runner.sh from-stage path: no artifact check or rehydration. **Fixed in implementation** — `_runner_from_stage_preflight` at runner.sh:1727.
- Gap 4 — `_cycle_orchestrator_run_body` reads `current_iter` unconditionally (cycle-orchestrator.sh:2325–2329), breaking nested loops. **NOT YET FIXED** — guard with `_ZBUILD_RESUME_ACTIVE` must still be added (step 6), and runner.sh must export `_ZBUILD_RESUME_ACTIVE=true` after line 2838 (step 7). The test at resume-loop-state-test.sh:76 must also export `_ZBUILD_RESUME_ACTIVE=true` before calling `cycle_orchestrator_run` (step 9).
- Gap 5 — ADR-006 and ADR-050 not amended. **Fixed in implementation.**
- Gap 6 — `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` directly but no test fails when the file is reverted to calling `_hydrate_put_back` inline. **NOT YET FIXED** — add SPEC-13 sentinel-mock delegation test (step 5).

**Decision:**
Extract the copy logic from `_hydrate_put_back` (plugins/tool/hydrate/plugin.sh) into a new `_artifact_persist_put_back <from> <to>` function in `core/state/artifact-persist.sh` (which the runner already sources). Redirect the hydrate plugin's `hydrate_run` call site (line 162) to the new function. At the single resume entry point in runner.sh (after `_runner_resume_rehydrate` at line 2838, before `eb_emit_event`), export `_ZBUILD_RESUME_ACTIVE=true` so cycle orchestrators know they are in resume context. In `_cycle_orchestrator_run_body` (cycle-orchestrator.sh:2325–2329), wrap the `_persisted_iter` read with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then … else _start_iter=1; fi` — only use persisted iter when actively resuming; otherwise start at 1. Change the stale-artifact branch from warn+continue to exit 1. Add a `_runner_from_stage_preflight` function called before the dispatch loop when `--from-stage` is active. Amend ADR-006 and ADR-050 to document these decisions.

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
- Redirect plugins/tool/hydrate/plugin.sh hydrate_run call site (line 162) to _artifact_persist_put_back (hydrate already sources artifact-persist.sh) | areas: plugins/tool/hydrate/plugin.sh
- Update tests/unit/hydrate-stage-test.sh: (a) line 216 already calls _artifact_persist_put_back directly — leave as-is; (b) add a new [#1805/SPEC-13] section that overrides _artifact_persist_put_back with a sentinel-writing function, runs hydrate_run against a minimal staging setup (existing _H_SRC / _H_FRESH context is available), and asserts the sentinel was written — this assertion fails when plugins/tool/hydrate/plugin.sh is reverted to calling _hydrate_put_back inline at line 162 (the override is never reached) | areas: tests/unit/hydrate-stage-test.sh
- Fix _cycle_orchestrator_run_body in core/pipeline/cycle-orchestrator.sh: replace the unconditional block at lines 2325–2329 with: `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]; then local _persisted_iter; _persisted_iter="$(get_state_field "$state_file" ".cycle_iterations[\"$cycle_id\"].current_iter" 0 2>/dev/null || echo 0)"; [[ "$_persisted_iter" =~ ^[0-9]+$ ]] || _persisted_iter=0; local _start_iter=$(( _persisted_iter + 1 )); else local _start_iter=1; fi` — when not in resume mode, _start_iter is always 1, restoring correct behaviour for fresh runs and nested-loop re-entries | areas: core/pipeline/cycle-orchestrator.sh
- In runner.sh, add `export _ZBUILD_RESUME_ACTIVE=true` on the line immediately after the _runner_resume_rehydrate call at runner.sh:2838 (before the eb_emit_event "pipeline.resume" call at line 2839); do NOT set it for fresh runs (the else branch at line 2845) | areas: core/pipeline/runner.sh
- Confirm tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, and tests/integration/cycle-member-dispatch-events-test.sh pass after the guard fix (they were broken by the unconditional current_iter read) | areas: tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh, tests/integration/nested-loop-rounds-test.sh, tests/integration/nested-loop-rounds-build-test.sh, tests/integration/cycle-member-dispatch-events-test.sh
- Update tests/integration/resume-loop-state-test.sh: add `export _ZBUILD_RESUME_ACTIVE=true` immediately before the cycle_orchestrator_run call at line 76 (the test calls the orchestrator directly, bypassing runner.sh; without this the guard added in step 6 prevents reading current_iter, _start_iter becomes 1, and the [#1805/SPEC-7] assertion "first dispatched iter is 2" fails) | areas: tests/integration/resume-loop-state-test.sh
- Update tests/integration/resume-rehydrate-test.sh: (1) fix the four grep-c anti-pattern sites near lines ~139, ~225, ~312, ~527 — replace `| grep -c '^...$' 2>/dev/null || echo 0` with `| wc -l | tr -d ' '`; (2) add `--no-resume` flag to the SPEC-12 runner invocation (line ~610) to prevent auto-resume; (3) remove the entire SPEC-12 cycled-dispatch block (the `_s12_cycled_starts` initialisation, the jq pipe, and the `assert_gt "[#1805/SPEC-12] fresh run dispatches cycled sub-stage"` assertion); (4) in the SPEC-13 section (lines ~634–645), retag the assert_contains label to `[#1805/SPEC-14]` — do NOT remove this assertion; (5) add assert_contains assertions for SPEC-5 (grep ADR-006-resume-contract.md for "resume-rehydrate-test.sh") and SPEC-6 (grep ADR-050-prior-work-reuse-contract.md for "ADR-006") | areas: tests/integration/resume-rehydrate-test.sh
- Update tests/integration/from-stage-rehydrate-test.sh: (1) fix the SPEC-3 zero-count assertion — replace `| grep -c '^intake$' 2>/dev/null || echo 0` with `| wc -l | tr -d ' '`; (2) in the SPEC-13 section (line ~268), retag the assert_contains label to `[#1805/SPEC-14]` — do NOT remove this assertion; (3) change the SPEC-4 assert_contains at line ~214-216 from checking for `"intake"` to checking for `"has no restorable primary artifact"` — this phrase appears only in the `_runner_from_stage_preflight` error at runner.sh:1751 and is absent from old code, making the assertion fail on old code and pass on new code | areas: tests/integration/from-stage-rehydrate-test.sh
- Verify tests/integration/resume-entry-points-test.sh: confirm no [#1805/SPEC-13]-tagged assertions remain and no untagged assert_gt for cycled sub-stage dispatch counts | areas: tests/integration/resume-entry-points-test.sh
- Verify tests/integration/pipeline-resume-test.sh: confirm intake's primary artifact is pre-written to ZBUILD_ARTIFACT_DIR before the --resume run (line 255 writes intake-result.json) | areas: tests/integration/pipeline-resume-test.sh
- Verify tests/integration/resume-after-sigint-test.sh: mock_plugin_factory "intake" at line 102 writes intake-result.json; the runner snapshots it after Phase 1; resume rehydration restores it; P2.T1 (rc=0) still passes with the SPEC-2 fail-closed path in effect | areas: tests/integration/resume-after-sigint-test.sh
- Run npm test and confirm full suite green | areas: core/pipeline/runner.sh, core/state/artifact-persist.sh, plugins/tool/hydrate/plugin.sh, core/pipeline/cycle-orchestrator.sh
```

```acceptance
SPEC-1[code]: On resume (all entry paths), before the dispatch loop, the runner calls _artifact_persist_restore and _artifact_persist_put_back and places completed-stage artifacts from the git state branch into ZBUILD_ARTIFACT_DIR; the complete stage emits no stage.start event covers: R-1 R-2 R-7
SPEC-2[code]: A complete stage whose primary artifact is absent from both disk and the git state branch causes the resume to exit 1 before any stage.start event is emitted covers: R-2
SPEC-3[code]: --from-stage <s> rehydrates all stages before <s> via _artifact_persist_restore and _artifact_persist_put_back, places their artifacts in ZBUILD_ARTIFACT_DIR, dispatches <s> as the first stage, and emits no stage.start for any earlier stage covers: R-4
SPEC-4[code]: --from-stage <s> when a stage before <s> has no restorable artifact emits the preflight diagnostic phrase "has no restorable primary artifact" to stderr (the phrase from _runner_from_stage_preflight at runner.sh:1751, absent from old code) and exits 1 before any stage.start event is emitted covers: R-8
SPEC-5[no-code]: ADR-006-resume-contract.md amended with step 3.6: before the dispatch loop the runner restores completed-stage artifacts from the git state branch; a still-absent artifact causes exit 1; enforcing test names (resume-rehydrate-test.sh, resume-entry-points-test.sh) added inline; verified by assert_contains in resume-rehydrate-test.sh greping ADR-006-resume-contract.md for "resume-rehydrate-test.sh" covers: R-5 R-12
SPEC-6[no-code]: ADR-050-prior-work-reuse-contract.md §6 amended with boundary note: the invariant applies to new runs; a resume continues the same run and is governed by ADR-006; verified by assert_contains in resume-rehydrate-test.sh greping ADR-050-prior-work-reuse-contract.md for "ADR-006" covers: R-6
SPEC-7[code]: Cycle orchestrator reads cycle_iterations[CYCLE_ID].current_iter from persisted state at resume and starts the iteration loop from that value (not 1); iter-1 complete stages emit no stage.start on resume into iter-2; the guard uses _ZBUILD_RESUME_ACTIVE so fresh runs and nested-loop re-entries always start at iter=1 covers: R-6 R-9
SPEC-8[done]: The dispatch loop skips any stage with stage_statuses[s]=="complete" during resume, so the run picks up at the first non-complete stage covers: R-3 evidence: core/pipeline/runner.sh:3896 core/pipeline/runner.sh:3899
SPEC-9[code]: All three resume entry paths (--resume flag to runner.sh, auto-resume on detecting status=interrupted, zbuild pipeline resume --run-id) invoke _runner_resume_rehydrate before the dispatch loop covers: R-9 R-12
SPEC-10[done]: A run with no prior state file proceeds as a fresh start with no rehydration covers: R-10 R-13 evidence: core/state/resume.sh:247 core/pipeline/runner.sh:2824
SPEC-11[done]: A new run of the same issue never skips a stage because the stage-skip guard requires resume_mode=true, which is false for new runs covers: R-11 R-14 evidence: core/pipeline/runner.sh:3896
SPEC-12[no-code]: tests/integration/resume-rehydrate-test.sh contains a sub-case that runs a fresh (non-resume) run using the same cycle fixture, with --no-resume to prevent auto-resume, and verifies intake dispatches and the fixture contains type:cycle, pinning the new-run side of the ADR-050 §6 boundary; together with the resume-side assertions in the same file (SPEC-1/SPEC-2), a single test file pins each side of the ADR-006/ADR-050 §6 boundary covers: R-13
SPEC-13[code]: The hydrate plugin's hydrate_run delegates its copy-back operation to _artifact_persist_put_back (not the old inline _hydrate_put_back); a sentinel-mock test in hydrate-stage-test.sh overrides _artifact_persist_put_back, calls hydrate_run, and asserts the mock was reached — fails when plugins/tool/hydrate/plugin.sh is reverted to calling _hydrate_put_back inline at line 162 covers: R-7
SPEC-14[no-code]: The test fixtures used by the R-1/R-2 tests (resume-rehydrate-test.sh) and the R-4/R-8 tests (from-stage-rehydrate-test.sh) each contain a pipeline stage of type: cycle, verified by an assert_contains tagged [#1805/SPEC-14] in each test file, ensuring R-1 through R-4 tests run against a cyclic pipeline covers: R-6
WIRING:
core/pipeline/runner.sh
core/pipeline/cycle-orchestrator.sh
plugins/tool/hydrate/plugin.sh
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
SPEC-13: tests/unit/hydrate-stage-test.sh
SPEC-14: tests/integration/resume-rehydrate-test.sh tests/integration/from-stage-rehydrate-test.sh
```

```supersedes
tests/integration/resume-after-sigint-test.sh: Phase 1 intake stub via mock_plugin_factory writes intake-result.json and the runner snapshots it; verify P2.T1 (rc=0) still passes with SPEC-2 fail-closed in effect
tests/integration/cycle-inner-iter-resets-per-outer-iter-test.sh: broken by unconditional current_iter read; after adding _ZBUILD_RESUME_ACTIVE guard (step 6), inner cycles start at iter=1 for fresh/nested-loop re-entries — these tests pass again
tests/integration/nested-loop-rounds-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/nested-loop-rounds-build-test.sh: broken by unconditional current_iter read; same fix restores correct behaviour
tests/integration/cycle-member-dispatch-events-test.sh: broken by unconditional current_iter read causing extra iterations and wrong verdict propagation; same fix restores correct behaviour
```

## Findings

**Finding 1 — design finding 1 fixed (R-9 coverage):** The previous design had SPEC-9 naming R-12 but not R-9. SPEC-9 tests that all three resume entry paths invoke `_runner_resume_rehydrate` before the dispatch loop — this is exactly what R-9 requires ("Every way to resume finds the interrupted run's state in runs/<run_id>/ and behaves as R-1"). Fixed: added `R-9` to SPEC-9's covers. SPEC-7 retains R-9 too since loop-state restoration is part of "behaving as R-1" during resume; this is permitted.

**Finding 2 — design finding 2 fixed (R-10 coverage):** The previous design had SPEC-3 naming R-10 but SPEC-3 is about --from-stage dispatch. SPEC-10[done] at resume.sh:247 covers no-prior-state → fresh-start, which is exactly R-10 ("A run with no prior state behaves exactly as today"). Fixed: added `R-10` to SPEC-10's covers.

**Finding 3 — design finding 3 fixed (R-12 coverage):** R-12 requires amending ADR-006 with the resume decision. SPEC-5 verifies this amendment via grep assertions (assert_contains greping ADR-006 for "resume-rehydrate-test.sh"). Fixed: added `R-12` to SPEC-5's covers. SPEC-9 also retains R-12 since the three entry-path test is the enforcing evidence the ADR names.

**Finding 4 — issue-acceptance findings 3 and 4 (ADR verification):** These are implementation concerns — the build must write the ADR amendments and add the grep-based assertions in step 10. The design already correctly specifies SPEC-5 with assert_contains greping ADR-006-resume-contract.md for "resume-rehydrate-test.sh", and SPEC-6 with assert_contains greping ADR-050 for "ADR-006". These are not design changes; they remain for the build stage.

**Finding 5 — SPEC-13 sentinel-mock delegation:** SPEC-13[code] covers R-7 (rehydration follows the hydrate plugin's path via _artifact_persist_put_back). Sentinel-mock test in hydrate-stage-test.sh proves delegation. WIRING includes plugins/tool/hydrate/plugin.sh.

**Finding 6 — Cycle orchestrator unconditional read (NOT YET FIXED):** `_cycle_orchestrator_run_body` at lines 2325–2329 reads `current_iter` unconditionally. Fix specified in step 6 (_ZBUILD_RESUME_ACTIVE guard), step 7 (runner.sh export), step 9 (test export). Previously verified: SPEC-7 NEGCTL PASS.

**Finding 7 — Evidence line numbers verified:** runner.sh:3896 = `if $resume_mode && [[ -z "$skip_until_stage" ]]; then`; runner.sh:3899 = `if [[ "$stage_status" == "complete" ]]; then`; resume.sh:247 = no-state-file → fresh_start branch.

**Finding 8 — Implementation state (verified):** `_artifact_persist_put_back` at artifact-persist.sh:638; `_artifact_persist_restore` at artifact-persist.sh:568; `_runner_resume_rehydrate` at runner.sh:1702, called at runner.sh:2838; plugins/tool/hydrate/plugin.sh line 162 calls `_artifact_persist_put_back`. SPEC-7, SPEC-9, SPEC-13 NEGCTL PASS.
