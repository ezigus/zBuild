# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Forty-first pass — Remove erroneous `_cd_iter > 0` guard; CMBR-1 emits stage.start for interrupted cycle member; ENTR-2 ZBUILD_STATE_FILE constraint tightened

### Changes this pass (forty-first)

**issue-acceptance finding 1** (PATH-1 / ENTR-2):
- The ENTR-2 test sets `ZBUILD_STATE_FILE="$P2_STATE_FILE"` at line 219 of resume-entry-points-test.sh
- This makes the symlink branch guard `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]` false
- The new code at runner.sh:2205 is dead in the test
- Design spec is correct (ENTR-2 Given says "ZBUILD_STATE_FILE and ZBUILD_STATE_DIR are unset")
- Fix: Added CRITICAL note to the ENTR-2 step in the design explicitly prohibiting ZBUILD_STATE_FILE from being set
- Also updated ENTR-2 Given to say "unset in the test environment" (more precise)

**issue-acceptance finding 2** (GUAR-1):
- The `_cd_iter > 0` guard fires for EVERY dispatch in EVERY run (`_cd_iter` starts at 1, so always ≥ 1)
- This changes fresh-run event sequences and breaks golden files:
  - `tests/golden/full-pipeline/event-sequence.golden`
  - `tests/golden/parity/event-sequence.golden`
- Previous design defense (findings 20/24) was WRONG: the guard does not preserve GUAR-1
- Fix: The `_cd_iter > 0` guard must be REMOVED
- DSPK-1's stage.start for cycle stage k's interrupted member comes from CMBR-1's `resume_first_iter=true` path explicitly emitting stage.start for the non-complete member
- For fresh runs and later resumed iterations (`resume_first_iter=false`): no stage.start for cycle members (pre-branch behavior, golden files preserved)
- FRSH-1 TESTFILES loses cycle-member-dispatch-events-test.sh (the assertion expected stage.start count which was wrong because: (a) cycle_dispatch_stage was stubbed so actual dispatch never happened, (b) the guard is now removed)
- Golden files added to scope
- Supersedes entry for cycle-member-dispatch-events-test.sh revised to remove the wrong stage.start expectations

### SPEC summary (16 SPECs: 11 [code], 5 [no-code], 3 REMOVED)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 |
| AMDR-2 | [no-code] | ADR-2 |
| ITER-1 | [code] | LOOP-1 |
| CMBR-1 | [code] | LOOP-1 |
| SKIP-1 | [code] | RESU-3 RESU-4 DISP-1 |
| DSPK-1 | [code] | RESU-3 RESU-4 |
| ENTR-1 | [code] | PATH-1 |
| ENTR-2 | [code] | PATH-1 |
| FRSH-1 | [no-code] | GUAR-1 |
| FRSH-2 | [no-code] | GUAR-2 |
| DLGT-1 | [code] | HYDR-1 |
| CYCL-1 | [no-code] | TEST-1 |
| REMOVED: DISP-1 | — | id collision |
| REMOVED: BNDY-1 | — | described file contents |
| REMOVED: LEGC-1 | — | DISP-1 covered by SKIP-1[code] |

All 16 requirements covered:
- RESU-1: RHYD-1
- RESU-2: RHYD-1, RHYD-2
- RESU-3: SKIP-1, DSPK-1
- RESU-4: RHYD-1, SKIP-1, DSPK-1
- FROM-1: FSTG-1
- FROM-2: FSTG-1
- FROM-3: FSTG-2
- LOOP-1: ITER-1, CMBR-1
- PATH-1: ENTR-1, ENTR-2
- GUAR-1: FRSH-1
- GUAR-2: FRSH-2
- ADR-1: AMDR-1
- ADR-2: AMDR-2
- HYDR-1: RHYD-1, DLGT-1
- TEST-1: CYCL-1
- DISP-1: SKIP-1

### Key structural facts (updated this pass)

1. **`_cd_iter > 0` guard is WRONG (this pass correction):**
   - `_cd_iter` starts at 1 → guard fires for every dispatch in every run
   - Breaks golden files for fresh-run event sequences
   - Issue-acceptance finding 2 confirms GUAR-1 violation
   - Guard must be removed from `_cycle_dispatch`

2. **DSPK-1 for cycle stages (corrected this pass):**
   - stage.start for the interrupted cycle member comes from CMBR-1's `resume_first_iter=true` path
   - `_cycle_dispatch` with `resume_first_iter=true`: (a) skip complete members (no stage.start); (b) emit stage.start for non-complete member, then dispatch normally
   - For fresh runs (`resume_first_iter=false`): no stage.start for cycle members (golden file behavior preserved)

3. **ENTR-2 test constraint (this pass):**
   - Test must NOT set ZBUILD_STATE_FILE or ZBUILD_STATE_DIR
   - Symlink guard: `[[ -z "${ZBUILD_STATE_FILE:-}" && -L "$state_dir/latest" ]]`
   - If ZBUILD_STATE_FILE is set, guard is false → code path dead
   - CRITICAL note added to ENTR-2 step

4. **FRSH-1 TESTFILES (this pass):**
   - Removed cycle-member-dispatch-events-test.sh
   - cycle_dispatch_stage is stubbed in that test → stage.start count always 0 regardless
   - FRSH-1 is now only pinned by resume-rehydrate-test.sh (fresh-run sub-case)

5. **`_ZBUILD_RESUME_ACTIVE` lifecycle (unchanged):**
   - Set `true` at runner.sh:2862 (resume entry, after `_runner_resume_rehydrate`)
   - Consumed (set `false`) at cycle-orchestrator.sh:2343 on first cycle orchestrator entry
   - Sole purpose: select `_start_iter`; not a general resume broadcast

6. **CMBR-1 implementation (Gap 9, still NOT YET FIXED in branch):**
   - Cycle orchestrator passes `resume_first_iter=true` to `_cycle_dispatch` for first resumed iteration
   - `_cycle_dispatch` skips complete members (no stage.start) and explicitly emits stage.start for interrupted member
   - Passed as local argument, no interaction with `_ZBUILD_RESUME_ACTIVE`

7. **FSTG-1 and DSPK-1 dispatch semantics (from fortieth pass, unchanged):**
   - For cycle stage k: cycle.start emitted for k by cycle:* arm; stage.start emitted for first non-complete member by CMBR-1 path
   - For leaf stage k: stage.start emitted normally by dispatch-unit loop

### Outstanding (requires build stage)

- Remove `_cd_iter > 0` unconditional stage.start guard from `_cycle_dispatch` if present
- Revert golden files if they were changed by the erroneous guard
- Fix ENTR-2 test: unset ZBUILD_STATE_FILE before the ENTR-2 sub-case
- CMBR-1 implementation: `_cycle_dispatch` skip-on-complete + explicit stage.start for interrupted member
- ADR-006 step 3.6 amendment (AMDR-1)
- ADR-050 §6 boundary note + Enforced by citations (AMDR-2)
- resume-loop-state-test.sh: needs CMBR-1 sub-case + `export _ZBUILD_RESUME_ACTIVE=true` for ITER-1
- cycle-member-dispatch-events-test.sh: update iter count assertions; remove wrong stage.start assertions
- Other test updates (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, hydrate-stage-test.sh)
