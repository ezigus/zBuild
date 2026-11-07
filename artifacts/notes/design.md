# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fortieth pass — FSTG-1 And and DSPK-1 Then corrected for cycle-stage dispatch semantics

### Changes this pass (fortieth)

**design finding 1** (from previous pass): FSTG-1 And says "a stage.start event is emitted for `<s>`" but `<s>=cyc` is a cycle stage — cycle stages emit `cycle.start` for the cycle ID and `stage.start` only for inner members. Test checks `cycle.start` for ordering (pipeline.resume before cycle.start) and `stage.start` for `cycled` (not `cyc`). The And was never satisfiable when `<s>` is a cycle stage.

**Resolution:** Changed FSTG-1 And to: "Stage <s> is dispatched as the first unit — when <s> is a cycle stage, a cycle.start event is emitted for <s> and stage.start is emitted for <s>'s first cycle member; when <s> is a leaf stage, a stage.start event is emitted for <s>; no corresponding dispatch event fires for any stage before <s>"

**design finding 2** (from previous pass): DSPK-1 Then says "Stage k emits a stage.start event" but k=cyc is a cycle stage — only cycle.start for the cycle ID, then stage.start for the inner member. Test checks stage.start for "cycled" (k's inner member), not for "cyc".

**Resolution:** Changed DSPK-1 Then to: "Stage k is dispatched — when k is a cycle stage, a cycle.start event is emitted for k and stage.start is emitted for k's first cycle member; when k is a leaf stage, a stage.start event is emitted for k"

**issue-acceptance finding 1** (GUAR-1 / `_cd_iter > 0` guard):
- Confirmed by git: `_cd_iter > 0` stage.start emission is absent from pre-branch commit d1da69bc — added by this branch
- Intentional: required for DSPK-1 (cycle members must emit stage.start so k's dispatch can be verified)
- Added cycle-member-dispatch-events-test.sh to FRSH-1's TESTFILES; that test (updated in supersedes) explicitly pins the new cycle member stage.start contract and would fail if the behavior were removed
- Updated Finding 24 to record this

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

### Key structural facts

1. **FSTG-1 dispatch semantics (this pass):**
   - Test fixture uses <s>=cyc (cycle stage)
   - cycle.start is emitted for cyc (not stage.start)
   - stage.start is emitted for cycled (the inner member of cyc)
   - FSTG-1 And now: "cycle.start for <s> when cycle stage, stage.start for first member; nothing for prior stages"

2. **DSPK-1 dispatch semantics (this pass):**
   - Test fixture uses k=cyc (cycle stage)
   - cycled inner member emits stage.start, not cyc itself
   - DSPK-1 Then now: "cycle.start for k when cycle stage, stage.start for k's first member"

3. **`_ZBUILD_RESUME_ACTIVE` lifecycle:**
   - Set `true` at runner.sh:2862 (resume entry, after `_runner_resume_rehydrate`)
   - Consumed (set `false`) at cycle-orchestrator.sh:2343 on first cycle orchestrator entry
   - Sole purpose: select `_start_iter` (read persisted iter vs. start at 1)
   - Any code called after orchestrator entry sees flag as false — this is by design

4. **`_cycle_dispatch` stage.start guard:**
   - `if [[ "$_cd_iter" -gt 0 ]]; then eb_emit_event "stage.start"`
   - Fires for all cycle member dispatches at iter > 0 (fresh and resume)
   - Absent from pre-branch d1da69bc — added by this branch intentionally
   - GUAR-1 satisfied by FRSH-1[no-code] + cycle-member-dispatch-events-test.sh

5. **CMBR-1 implementation (Gap 9, NOT YET FIXED in branch):**
   - Cycle orchestrator passes `resume_first_iter=true` to `_cycle_dispatch` for first
     iteration dispatched during a resume (when `_start_iter > 1`, current_iter == `_start_iter`)
   - `_cycle_dispatch` skips members already marked complete when flag is set
   - Passed as local argument, no interaction with `_ZBUILD_RESUME_ACTIVE`

6. **Gap 8 (auto-resume state discovery) FIXED in branch:**
   - runner.sh auto-resume elif extended to check `$state_dir/latest/pipeline-state.json`
   - ENTR-2[code] tests this without ZBUILD_STATE_FILE set

### Outstanding (requires build stage)

- CMBR-1 implementation: `_cycle_dispatch` skip-on-complete guard for first resumed iteration
- ADR-006 step 3.6 amendment (AMDR-1)
- ADR-050 §6 boundary note + Enforced by citations (AMDR-2)
- resume-loop-state-test.sh: needs CMBR-1 sub-case + `export _ZBUILD_RESUME_ACTIVE=true` for ITER-1
- cycle-member-dispatch-events-test.sh: needs update for stage.start at iter > 0
- Other test updates (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, hydrate-stage-test.sh)
