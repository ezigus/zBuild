# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Thirty-fifth pass — CMBR-1[code] added for LOOP-1 within-iteration member skip (design finding 1)

### Change this pass

**design finding 1** (from previous pass design verdict: unusable):
LOOP-1 was only partially covered. ITER-1 covers restoring the iteration count so the cycle
orchestrator starts at iter k (not iter 1). But no SPEC covered skipping already-complete member
stages WITHIN that iteration. If build completed in iter 2 before test was interrupted, build
would re-run on resume because `_cycle_dispatch` has no skip-on-complete guard — it emits
`stage.start` for all members at `_cd_iter > 0` unconditionally. SKIP-1's skip guard is in the
top-level dispatch-unit loop only.

LOOP-1 says "resumes at the interrupted stage of that round" — this requires BOTH:
1. Starting at the right iteration (ITER-1) — ALREADY COVERED
2. Skipping already-complete members within that iteration (CMBR-1) — NEW

**CMBR-1[code]** added: covers LOOP-1. Implementation (Gap 9, NOT YET FIXED):
- Cycle orchestrator passes `resume_first_iter=true` to `_cycle_dispatch` only when dispatching
  members of `_start_iter` during a resume (i.e., `_start_iter > 1`, current iter == `_start_iter`)
- `_cycle_dispatch` with that flag checks the cycle member stage's persisted status and skips
  (no stage.start, no dispatch) any member already marked complete
- Flag is passed as a local argument — no interaction with `_ZBUILD_RESUME_ACTIVE` (already consumed)
- Test: resume-loop-state-test.sh (alongside ITER-1)
- Touches: core/pipeline/runner.sh (where `_cycle_dispatch` is defined ~line 3204) and
  core/pipeline/cycle-orchestrator.sh (where it is called from)

### Changes made to design-draft.md

- Goal in architectural decision: added sentence about within-iteration cycle member skip
- Gap 9 added to Decision section (NOT YET FIXED)
- Decision section: added CMBR-1 implementation approach (resume_first_iter flag)
- Steps block: split resume-loop-state-test.sh update step to also add CMBR-1 sub-case;
  added new step for the `_cycle_dispatch` skip-on-complete guard implementation
- Acceptance block: CMBR-1[code] added after ITER-1, covers: LOOP-1
  Given/When/Then: iter k, build complete, test interrupted; resume; no stage.start for build, yes for test
- TESTFILES: CMBR-1: tests/integration/resume-loop-state-test.sh
- Finding 1: updated SPEC list to include CMBR-1; noted Finding 23
- Finding 3: LOOP-1 coverage updated to ITER-1 + CMBR-1 with explanation
- Finding 23: added explaining the gap and the CMBR-1 fix

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

### Outstanding (requires build stage)

- CMBR-1 implementation: `_cycle_dispatch` skip-on-complete guard for first resumed iteration
  (Gap 9, NOT YET FIXED) — touches runner.sh and cycle-orchestrator.sh
- runner.sh auto-resume elif needs `latest` symlink check (Gap 8) — still NOT YET FIXED
- resume-entry-points-test.sh needs ENTR-2 sub-case
- ADR-006 step 3.6 amendment (AMDR-1)
- ADR-050 §6 boundary note + Enforced by citations (AMDR-2)
- resume-loop-state-test.sh: needs CMBR-1 sub-case + `export _ZBUILD_RESUME_ACTIVE=true` for ITER-1
- cycle-member-dispatch-events-test.sh: needs update for stage.start at iter > 0
- Other test updates (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh, hydrate-stage-test.sh)

### Key structural facts

1. `_ZBUILD_RESUME_ACTIVE` lifecycle:
   - Set `true` at runner.sh:2862 (resume entry, after `_runner_resume_rehydrate`)
   - Consumed (set `false`) at cycle-orchestrator.sh:2343 on first cycle orchestrator entry
   - Sole purpose: selecting `_start_iter` in cycle orchestrator
   - NOT a general "this dispatch is part of a resume" signal — flag is false when _cycle_dispatch runs

2. `stage.start` for cycle members:
   - `_cycle_dispatch` (runner.sh:3204) emits `stage.start` for `_cd_iter > 0` unconditionally
   - Fires for resume (stage k → DSPK-1) AND fresh cycle runs (iter 1+)
   - Event-contract widening vs pre-branch: cycle-member-dispatch-events-test.sh must be updated

3. CMBR-1 fix mechanism:
   - Cycle orchestrator knows `_start_iter` (from ITER-1 fix)
   - When dispatching iter == `_start_iter` and `_start_iter > 1`, pass `resume_first_iter=true`
   - `_cycle_dispatch` with that flag: check stage status in persisted state, skip if complete
   - For subsequent iters (iter > `_start_iter`): `resume_first_iter=false`, no skip

4. ITER-1 fix: already in branch (cycle-orchestrator.sh:2337-2349)
5. Auto-resume state discovery (Gap 8): NOT YET FIXED in runner.sh
