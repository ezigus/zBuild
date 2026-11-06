# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Thirty-third pass — issue-acceptance PATH-1 gap addressed (auto-resume state discovery)

### Change this pass

**Issue-acceptance finding (PATH-1):** The auto-resume check in runner.sh (line 2174) tests
`[[ -f "$state_file" ]]` where `state_file = $state_dir/pipeline-state.json`. Per-run layout
(ADR-059 §1) stores state at `runs/<run_id>/pipeline-state.json`, not the flat root path.
Result: without ZBUILD_STATE_FILE set, auto-resume never fires. All existing auto-resume tests
mask this by setting ZBUILD_STATE_FILE directly.

**Fix verified:** `_find_state_file` in `scripts/zbuild` already scans `runs/*/pipeline-state*.json`
and also checks `$state_dir/latest/pipeline-state.json`. Runner.sh needs to do the same in its
auto-resume elif.

Changes made to design-draft.md:
- Added Gap 8 to context section
- Updated Decision section to include the `latest` symlink fix
- Added step 7b: runner.sh auto-resume elif extended to check `$state_dir/latest/pipeline-state.json`
- Added step: update resume-entry-points-test.sh with [#1805/ENTR-2] sub-case
- Added ENTR-2[code] to acceptance block (auto-resume state discovery from `runs/<run_id>/` via `latest` symlink, no ZBUILD_STATE_FILE set)
- Updated TESTFILES: ENTR-2: tests/integration/resume-entry-points-test.sh
- Updated Finding 1 (list ENTR-2), Finding 3 (PATH-1 now covered by ENTR-1 AND ENTR-2)
- Added Finding 21 (the issue-acceptance finding and resolution)

**ENTR-2 pre/post test behavior:**
- Pre-change: state at `runs/<run_id>/`, ZBUILD_STATE_FILE unset → state_file = flat root path →
  `[[ -f ]]` false → auto-resume elif skips → no pipeline.resume event → test FAILS ✓
- After fix: auto-resume elif checks `latest/pipeline-state.json` → found →
  recommendation=auto_resume → fires → pipeline.resume emitted → test PASSES ✓

### SPEC summary (this pass — 15 SPECs, 10 [code], 5 [no-code], 3 REMOVED)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 |
| AMDR-2 | [no-code] | ADR-2 |
| ITER-1 | [code] | LOOP-1 |
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

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with
  `_ZBUILD_RESUME_ACTIVE` needed (step 6)
- `resume-loop-state-test.sh` needs `export _ZBUILD_RESUME_ACTIVE=true` (step 9)
- `_cycle_dispatch` runner.sh:3166 stage.start guard must be narrowed to resume-only (step 7a)
- runner.sh auto-resume elif needs `latest` symlink check (step 7b) — NEW this pass
- resume-entry-points-test.sh needs ENTR-2 sub-case (new step) — NEW this pass
- ADR-006 step 3.6 amendment (AMDR-1)
- ADR-050 §6 boundary note + Enforced by citations (AMDR-2)

## Status: Thirty-second pass — scope lens finding 1 addressed (cycle member stage.start guard)

### Change this pass

**Scope lens finding 1:** The diff at runner.sh:3166 adds `stage.start` emission for ALL cycle
member dispatches (iter > 0), not just during resume. This is broader than DSPK-1 requires and
changes the event contract for fresh cycle-based runs.

**Verified via git diff main..HEAD -- core/pipeline/runner.sh**: The code at 3166 IS new (added
by this branch). The fix: guard with `${_ZBUILD_RESUME_ACTIVE:-false} == true` so cycle members
only emit stage.start in resume mode. `resume_mode` is a local variable inaccessible inside
`_cycle_dispatch`; `_ZBUILD_RESUME_ACTIVE` is exported and correctly scoped.

Changes made to design-draft.md:
- Added Gap 7 in architectural decision context
- Updated Decision section to include the stage.start guard fix
- Added step 7a in steps block to guard runner.sh:3166
- Added Finding 20 explaining the scope lens finding and fix

The DSPK-1 SPEC itself is unchanged — it correctly scopes to "On resume, stage k emits
stage.start." The test in resume-rehydrate-test.sh checks for stage.start of "cycled" with
`_ZBUILD_RESUME_ACTIVE=true` exported, so it still passes after the guard.

## Status: Thirty-first pass — ORDE-1 removed from requirements, design cleaned up

### Change this pass

**Intake removed ORDE-1** from the requirement set (it was a process/ordering constraint, not a
code requirement: "Do not run this in parallel with another issue that edits the dispatch loop").
The design previously had `AMDR-1[no-code]` with `covers: ADR-1 ORDE-1`.

Changes made to design-draft.md:
- AMDR-1 `covers:` reduced to `covers: ADR-1`
- Finding 2 updated: 16 requirements, ORDE-1 no longer listed
- Finding 3 updated: "All 16 requirements covered", ORDE-1 row removed
- Finding 17 updated: explains ORDE-1 removed by intake; constraint prose still belongs in ADR-006 amendment

### Issue-acceptance finding 1 (ORDE-1)
Not a design gap. Intake already removed ORDE-1. The issue-acceptance finding is moot.
ANSWER design finding 1: nothing to do — intake removed ORDE-1 from requirements; AMDR-1 covers
field updated to `covers: ADR-1` only; count corrected to 16 requirements.

### SPEC summary (this pass)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 |
| AMDR-2 | [no-code] | ADR-2 |
| ITER-1 | [code] | LOOP-1 |
| SKIP-1 | [code] | RESU-3 RESU-4 DISP-1 |
| DSPK-1 | [code] | RESU-3 RESU-4 |
| ENTR-1 | [code] | PATH-1 |
| FRSH-1 | [no-code] | GUAR-1 |
| FRSH-2 | [no-code] | GUAR-2 |
| DLGT-1 | [code] | HYDR-1 |
| CYCL-1 | [no-code] | TEST-1 |
| REMOVED: DISP-1 | — | id collision with requirement DISP-1 |
| REMOVED: BNDY-1 | — | described file contents |
| REMOVED: LEGC-1 | — | DISP-1 covered by SKIP-1[code] |

**Counts: 9 [code], 5 [no-code], 0 [done], 3 REMOVED**

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with
  `_ZBUILD_RESUME_ACTIVE` needed (step 6 of the design steps)
- `resume-loop-state-test.sh` needs `export _ZBUILD_RESUME_ACTIVE=true` before
  `cycle_orchestrator_run` call (step 9 of the design steps)
- ADR-006 step 3.6 amendment must be written to the file (AMDR-1; test greps for it)
- ADR-050 §6 boundary note + Enforced by citations must be written to the file (AMDR-2; test greps for them)

## Previous pass notes (thirtieth pass — no changes required)

Issue-acceptance NOT SURE R-5 (ADR-006 step 3.6): resolved — AMDR-1[no-code] specifies a test
that greps for step 3.6 amendment text. If absent, test fails. Build-stage gap, not design gap.

Issue-acceptance NOT SURE R-6 (ADR-050 §6 boundary note): resolved — AMDR-2[no-code] specifies
a test that greps for the boundary note text and Enforced by citations. Build-stage gap.

Issue-acceptance first point (dispatch-unit loop regression on non-resume paths): resolved —
FRSH-1[no-code] and FRSH-2[no-code] cover GUAR-1 and GUAR-2; skip guards conditioned on
`$resume_mode`; fresh runs never activate them. Build/test concern, not design gap.

## Previous pass notes (twenty-ninth pass — AMDR-2 widened)

AMDR-2 now explicitly requires adding citations for FRSH-2 (resume-rehydrate-test.sh, new-run
side) and ENTR-1 (resume-entry-points-test.sh, resume side) to ADR-050 §6's Enforced by entry.
Step 2 updated to match.

## Previous pass notes (twenty-eighth pass — SKIP-1[code], FRSH-2[no-code], LEGC-1 REMOVED)

The dispatch-unit skip-on-complete guards are at:
- runner.sh:3442 (`cycle:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- runner.sh:3728 (`stage:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`

Both were added by this branch. The only pre-existing skip guard is in the legacy linear loop
at runner.sh:3895, which DISP-1 forbids using as evidence.

SKIP-1 changed to [code]; FRSH-2 to [no-code]; LEGC-1 REMOVED.
