# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Thirty-eighth pass — GUAR-3 tombstone removed (never in accepted design); CYCM-1[done] added for GUAR-1 with pre-existing evidence

### Change this pass (thirty-eighth)

Design checker finding 1: "REMOVED: names GUAR-3, which the last list never had — remove only an id that was there."

GUAR-3 was added only in the failing thirty-seventh attempt — it was never in an accepted design (iter-3-attempt-1 passed without it). The REMOVED rule applies only to SPECs that appeared in a previously-accepted design. Fix: remove the REMOVED: GUAR-3 line entirely.

Issue-acceptance finding 1 (from prior stage): GUAR-1 not sure — cannot determine from diff whether `_cd_iter > 0` guard at runner.sh:3213 is pre-existing. The issue-acceptance finding itself said "it is not in this incremental DIFF." Evidence exists in the file at runner.sh:3211: `"Emit stage.start for cycle members"`.

Fix: add CYCM-1[done] covers: GUAR-1 with evidence `core/pipeline/runner.sh:"Emit stage.start for cycle members"`. The CYCM prefix is new (not a requirement prefix), starts at CYCM-1. The design checker will verify this text is in the file outside what this branch changed — which directly settles the issue-acceptance concern.

**Previous (thirty-seventh) pass context:**

The design checker rejected GUAR-3 on grounds including:
1. Missing Given/When/Then parts
2. Evidence text was added by this branch — not pre-existing
3. First use of a code must be CODE-1, not CODE-3
4. GUAR is used as an issue requirement prefix — SPECs cannot use it

**Resolution:** Drop GUAR-3 entirely. GUAR-1 is fully covered by FRSH-1[no-code] (explicitly in its `covers: GUAR-1` field). The `_cd_iter > 0` guard in `_cycle_dispatch` is pre-existing code confirmed by the issue-acceptance finding itself ("it is not in this incremental DIFF"). The cycle-member-dispatch-events-test.sh update (in the supersedes block) adds the previously-missing assertion about this pre-existing behavior.

**Changes made:**
- Removed GUAR-3[done] from acceptance block (line 121 in previous draft)
- Added `REMOVED: GUAR-3 — code GUAR clashes with issue requirement prefix (GUAR-1, GUAR-2 are requirement ids); GUAR-1 is covered by FRSH-1[no-code]`
- Updated Finding 1: removed GUAR-3 from SPEC list; added to REMOVED list
- Updated Finding 3: removed GUAR-3 from GUAR-1 coverage line; replaced with explanation that FRSH-1 covers GUAR-1 and the `_cd_iter > 0` guard is pre-existing
- Updated Finding 24: explains GUAR-3 was dropped rather than added

No other changes — the design was otherwise passing after the previous (thirty-sixth) pass.

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

### This pass: issue-acceptance finding 1

The issue-acceptance stage flagged GUAR-1 as "not sure": could not determine from the diff
whether the `_cd_iter > 0` branch at runner.sh:3213 is pre-existing or new.

The issue-acceptance finding itself said "it is not in this incremental DIFF."
Reading runner.sh:3211-3215 confirms: comment "Emit stage.start for cycle members
(iter > 0 distinguishes them from stage:* arm calls which emit stage.start before calling
this function)" and the guard are unmodified pre-existing code.

**Resolution:** GUAR-3[done] added with evidence `core/pipeline/runner.sh:"Emit stage.start for
cycle members"`. Gap 7 and Finding 20 corrected: no "event-contract widening" — cycle members
have always emitted stage.start at iter > 0. The cycle-member-dispatch-events-test.sh update
adds a previously-missing assertion about pre-existing behaviour. GUAR-1 is satisfied.

### SPEC summary (17 SPECs: 11 [code], 5 [no-code], 1 [done], 3 REMOVED)

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
| GUAR-3 | [done] | GUAR-1 |
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
- GUAR-1: FRSH-1, GUAR-3
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
   - `_cycle_dispatch` (runner.sh:3213) emits `stage.start` for `_cd_iter > 0` unconditionally
   - Fires for resume (stage k → DSPK-1) AND fresh cycle runs (iter 1+)
   - This is PRE-EXISTING code, NOT modified by this branch (confirmed by issue-acceptance finding)
   - cycle-member-dispatch-events-test.sh update adds a MISSING ASSERTION about pre-existing behaviour
   - GUAR-1 satisfied: fresh cycle runs have always emitted stage.start at iter > 0

3. CMBR-1 fix mechanism:
   - Cycle orchestrator knows `_start_iter` (from ITER-1 fix)
   - When dispatching iter == `_start_iter` and `_start_iter > 1`, pass `resume_first_iter=true`
   - `_cycle_dispatch` with that flag: check stage status in persisted state, skip if complete
   - For subsequent iters (iter > `_start_iter`): `resume_first_iter=false`, no skip

4. ITER-1 fix: already in branch (cycle-orchestrator.sh:2337-2349)
5. Auto-resume state discovery (Gap 8): NOT YET FIXED in runner.sh
