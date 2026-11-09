# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Forty-ninth pass — DSFSTG-3 added for post-target stage skip in combined mode

### Changes this pass (forty-ninth)

**lens-correctness-design finding 1** (combined --resume --from-stage <cycle>: stages after target skipped):
- After target unit is found and `skip_until_stage` is cleared (runner.sh:3653, 3977), `resume_mode` stays true
- Resume skip guard `$resume_mode && [[ -z "$skip_until_stage" ]]` fires for all subsequent units
- Any subsequent unit marked complete in the interrupted run's state is silently skipped
- RQFROM-1 says "the run starts at <s>" — all stages from <s> onward must dispatch
- Fix: add `resume_mode=false` immediately after clearing `skip_until_stage` in both arms
- Added Gap 11 to architectural decision
- Added `resume_mode=false` to the Decision paragraph
- Added DSFSTG-3[code] covers RQFROM-1
- Updated from-stage-rehydrate-test.sh step to add DSFSTG-3 assertion (3-unit fixture)
- Added DSFSTG-3 to TESTFILES
- Updated Finding 1 (DSFSTG-3), Finding 3 (RQFROM-1: DSFSTG-1 + DSFSTG-3), Finding 30

---

## Status: Forty-eighth pass — DSFRSH-2 Then corrected for cycle event semantics

### Changes this pass (forty-eighth)

**design finding 1** (DSFRSH-2 Then: "count of stage.start == total declared stages" wrong for cycle fixture):
- Fixture has `intake` (leaf → `stage.start`) and `cyc` (cycle → `cycle.start`)
- In a fresh run, stage.start count = 1 (intake only); cycle stages emit `cycle.start`, not `stage.start`
- Previous Then: "count of stage.start == total declared stages" → "1 == 2" → FAILS for correct behavior
- Fix: Changed Then to "combined count of stage.start (leaf stages) + cycle.start (cycle stages) equals total declared stages"
- With fixture: 1 stage.start + 1 cycle.start = 2 == 2 declared stages ✓
- Updated Finding 29 to explain the cycle-semantics correction

---

## Status: Forty-sixth pass — DSCMBR-1 Given fixed ("in-progress" → "aborted")

### Changes this pass (forty-sixth)

**test-author finding 1** (DSCMBR-1 Given uses wrong status value):
- Test sets `stage_statuses.test = "aborted"` for iter-2 (the production value for interrupted stages)
- DSCMBR-1's Given said "test as in-progress" — wrong; "aborted" is the production status value
- Fix: Changed "test as in-progress" to "test as aborted" in the Given clause
- Added Finding 28 documenting this change

---

## Status: Forty-fifth pass — DSFSTG-1 And clause fixed (mechanism text removed)

### Changes this pass (forty-fifth)

**design finding 1** (DSFSTG-1 names internal mechanisms in 4th And clause):
- The clause "rehydration and dispatch-loop skip guards prevent it, satisfying RQFROM-2 in both pure from-stage and combined resume+from-stage modes" names implementation details, not observable behavior
- Fix: Removed the mechanism explanation; rewritten as: "And: `pipeline.skip_to_stage` is emitted when `--from-stage` is active; no stage before <s> is dispatched after that event"
- This is fully observable: the event appears in the event log; no stage.start for stages before <s> appears after it

**lens-correctness-design finding 1** (pipeline.skip_to_stage in resume+from-stage mode):
- Now fully addressed by the DSFSTG-1 fix above
- DSFSTG-1's 4th And states only observable behavior; Gap 10 in the architectural decision explains the analysis in context terms only (not an acceptance assertion)

---

## Status: Forty-fourth pass — artifact-persist.sh scope defended; skip_to_stage lens finding addressed

### Changes this pass (forty-fourth)

**design finding 1** (remove core/state/artifact-persist.sh from scope):
- Answered "wrong" — the file IS created by this change to satisfy RQHYDR-1
- Scope block must list every file the change touches; removing it makes scope incomplete
- RQHYDR-1's directive to reuse the hydrate path motivates the extraction
- Added Finding 10 to the design explaining the reasoning
- File kept in scope

**lens-correctness-design finding 1** (pipeline.skip_to_stage in resume+from-stage mode):
- runner.sh:2963 emits the event when --from-stage is active, including combined resume+from-stage
- RQFROM-2 says the event must not be FOLLOWED BY running an earlier stage
- That constraint IS met: rehydration + dispatch-loop skip guards prevent earlier-stage dispatch
- No code change needed — existing behavior satisfies RQFROM-2
- Added Gap 10 to architectural decision explaining this
- Added a 4th Then clause to DSFSTG-1: explicitly states the event is emitted in both modes and RQFROM-2 is satisfied by the guards
- Added Finding 27 explaining the analysis

### Changes this pass (forty-third)

**Design finding 1** (RQTEST-1 not fully covered by DSCYCL-1):
- DSCYCL-1 previously only covered resume-rehydrate-test.sh and from-stage-rehydrate-test.sh
- RQTEST-1 says "Tests for RQRESU-4, RQLOOP-1, RQFROM-2, RQFROM-3, and RQPATH-1 must use a cycle"
- RQLOOP-1 is tested by resume-loop-state-test.sh; RQPATH-1 by resume-entry-points-test.sh — both were missing
- Fix: DSCYCL-1 text updated to name all 4 test files; TESTFILES for DSCYCL-1 extended to include resume-loop-state-test.sh and resume-entry-points-test.sh
- Update steps for resume-loop-state-test.sh and resume-entry-points-test.sh each gain an [#1805/DSCYCL-1] assertion item

### Changes this pass (forty-second)

**issue-acceptance finding 1** (RQPATH-1 / DSENTR-2):
- The DSENTR-2 test sets `ZBUILD_STATE_FILE="$P2_STATE_FILE"` at line 219 of resume-entry-points-test.sh
- This makes the symlink branch guard `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` false
- The new code at runner.sh:2205 is dead in the test
- Design spec is correct (DSENTR-2 Given says "ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset")
- Fix: Added CRITICAL note to the DSENTR-2 step in the design explicitly prohibiting ZBUILD_STATE_FILE from being set
- Also updated DSENTR-2 Given to say "unset in the test environment" (more precise)

**issue-acceptance finding 2** (RQGUAR-1):
- The `_cd_iter > 0` guard fires for EVERY dispatch in EVERY run (`_cd_iter` starts at 1, so always ≥ 1)
- This changes fresh-run event sequences and breaks golden files:
  - `tests/golden/full-pipeline/event-sequence.golden`
  - `tests/golden/parity/event-sequence.golden`
- Previous design defense (findings 20/24) was WRONG: the guard does not preserve RQGUAR-1
- Fix: The `_cd_iter > 0` guard must be REMOVED
- DSDSPK-1's stage.start for cycle stage k's interrupted member comes from DSCMBR-1's `resume_first_iter=true` path explicitly emitting stage.start for the non-complete member
- For fresh runs and later resumed iterations (`resume_first_iter=false`): no stage.start for cycle members (pre-branch behavior, golden files preserved)
- DSFRSH-1 TESTFILES loses cycle-member-dispatch-events-test.sh (the assertion expected stage.start count which was wrong because: (a) cycle_dispatch_stage was stubbed so actual dispatch never happened, (b) the guard is now removed)
- Golden files added to scope
- Supersedes entry for cycle-member-dispatch-events-test.sh revised to remove the wrong stage.start expectations

### SPEC summary (16 SPECs: 11 [code], 5 [no-code], 3 REMOVED)

| SPEC | Classification | Covers |
|------|---------------|--------|
| DSRHYD-1 | [code] | RQRESU-1 RQRESU-2 RQRESU-4 RQHYDR-1 |
| DSRHYD-2 | [code] | RQRESU-2 |
| DSFSTG-1 | [code] | RQFROM-1 RQFROM-2 |
| DSFSTG-2 | [code] | RQFROM-3 |
| DSAMDR-1 | [no-code] | RQADR-1 |
| DSAMDR-2 | [no-code] | RQADR-2 |
| DSITER-1 | [code] | RQLOOP-1 |
| DSCMBR-1 | [code] | RQLOOP-1 |
| DSSKIP-1 | [code] | RQRESU-3 RQRESU-4 RQDISP-1 |
| DSDSPK-1 | [code] | RQRESU-3 RQRESU-4 |
| DSENTR-1 | [code] | RQPATH-1 |
| DSENTR-2 | [code] | RQPATH-1 |
| DSFRSH-1 | [no-code] | RQGUAR-1 |
| DSFRSH-2 | [no-code] | RQGUAR-2 |
| DSDLGT-1 | [code] | RQHYDR-1 |
| DSCYCL-1 | [no-code] | RQTEST-1 |
| REMOVED: RQDISP-1 | — | id collision |
| REMOVED: DSBNDY-1 | — | described file contents |
| REMOVED: DSLEGC-1 | — | RQDISP-1 covered by DSSKIP-1[code] |

All 16 requirements covered:
- RQRESU-1: DSRHYD-1
- RQRESU-2: DSRHYD-1, DSRHYD-2
- RQRESU-3: DSSKIP-1, DSDSPK-1
- RQRESU-4: DSRHYD-1, DSSKIP-1, DSDSPK-1
- RQFROM-1: DSFSTG-1
- RQFROM-2: DSFSTG-1
- RQFROM-3: DSFSTG-2
- RQLOOP-1: DSITER-1, DSCMBR-1
- RQPATH-1: DSENTR-1, DSENTR-2
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1
- RQADR-2: DSAMDR-2
- RQHYDR-1: DSRHYD-1, DSDLGT-1
- RQTEST-1: DSCYCL-1
- RQDISP-1: DSSKIP-1

### Key structural facts (updated this pass)

1. **`_cd_iter > 0` guard is WRONG (this pass correction):**
   - `_cd_iter` starts at 1 → guard fires for every dispatch in every run
   - Breaks golden files for fresh-run event sequences
   - Issue-acceptance finding 2 confirms RQGUAR-1 violation
   - Guard must be removed from `_cycle_dispatch`

2. **DSDSPK-1 for cycle stages (corrected this pass):**
   - stage.start for the interrupted cycle member comes from DSCMBR-1's `resume_first_iter=true` path
   - `_cycle_dispatch` with `resume_first_iter=true`: (a) skip complete members (no stage.start); (b) emit stage.start for non-complete member, then dispatch normally
   - For fresh runs (`resume_first_iter=false`): no stage.start for cycle members (golden file behavior preserved)

3. **DSENTR-2 test constraint (this pass):**
   - Test must NOT set ZBUILD_STATE_FILE or ZBUILD_STATE_DIR
   - Symlink guard: `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]`
   - If ZBUILD_STATE_FILE is set, guard is false → code path dead
   - CRITICAL note added to DSENTR-2 step

4. **DSFRSH-1 TESTFILES (this pass):**
   - Removed cycle-member-dispatch-events-test.sh
   - cycle_dispatch_stage is stubbed in that test → stage.start count always 0 regardless
   - DSFRSH-1 is now only pinned by resume-rehydrate-test.sh (fresh-run sub-case)

5. **`_ZBUILD_RESUME_ACTIVE` lifecycle (unchanged):**
   - Set `true` at runner.sh:2862 (resume entry, after `_runner_resume_rehydrate`)
   - Consumed (set `false`) at cycle-orchestrator.sh:2343 on first cycle orchestrator entry
   - Sole purpose: select `_start_iter`; not a general resume broadcast

6. **DSCMBR-1 implementation (Gap 9, still NOT YET FIXED in branch):**
   - Cycle orchestrator passes `resume_first_iter=true` to `_cycle_dispatch` for first resumed iteration
   - `_cycle_dispatch` skips complete members (no stage.start) and explicitly emits stage.start for interrupted member
   - Passed as local argument, no interaction with `_ZBUILD_RESUME_ACTIVE`

7. **DSFSTG-1 and DSDSPK-1 dispatch semantics (from fortieth pass, unchanged):**
   - For cycle stage k: cycle.start emitted for k by cycle:* arm; stage.start emitted for first non-complete member by DSCMBR-1 path
   - For leaf stage k: stage.start emitted normally by dispatch-unit loop

### Outstanding (requires build stage)

- Remove `_cd_iter > 0` unconditional stage.start guard from `_cycle_dispatch` if present
- Revert golden files if they were changed by the erroneous guard
- Fix DSENTR-2 test: unset ZBUILD_STATE_FILE before the DSENTR-2 sub-case
- DSCMBR-1 implementation: `_cycle_dispatch` skip-on-complete + explicit stage.start for interrupted member
- ADR-006 step 3.6 amendment (DSAMDR-1)
- ADR-050 §6 boundary note + Enforced by citations (DSAMDR-2)
- resume-loop-state-test.sh: needs DSCMBR-1 sub-case + `export _ZBUILD_RESUME_ACTIVE=true` for DSITER-1
- cycle-member-dispatch-events-test.sh: update iter count assertions; remove wrong stage.start assertions
- Other test updates (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, hydrate-stage-test.sh)
