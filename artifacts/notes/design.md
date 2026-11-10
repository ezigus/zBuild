# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fifty-sixth pass — DSFSTG-4 reclassified from [code] to [done]

### What changed this pass

**acceptance-gate finding 1:** DSFSTG-4's test already passes on the code from before this
change (base code), so it cannot tell whether the change was made.

**Root cause:** In the base code, the `--from-stage` validation guard is at runner.sh line 1737,
BEFORE the auto-resume check at line 2081. So a test of "exits 1 when --from-stage without
--resume, even with auto-resume conditions" passes on base code — the guard fires before
auto-resume ever runs. The branch moved the guard AFTER auto-resume (a regression). The fix
(Gap 12) moves it back before auto-resume, restoring the pre-existing behavior.

For [code] semantics, the test must FAIL on base code. It doesn't. So DSFSTG-4 must be [done].

**Changes made:**
1. DSFSTG-4[code] → DSFSTG-4[done] with evidence:
   `core/pipeline/runner.sh:"--from-stage is only valid with --resume"` (confirmed in base code)
2. Removed the [#1805/DSFSTG-4] sub-case from the from-stage-rehydrate-test.sh step
   (no test written for [done] SPECs)
3. Removed DSFSTG-4 from TESTFILES section
4. Updated Finding 1 (DSFSTG-4 now [done])
5. Updated Finding 3 (RQFROM-4: DSFSTG-4[done])
6. Updated Finding 32 (explains [done] rationale)

**Gap 12 fix step remains unchanged:** The step that moves the guard before auto-resume
is still in the steps block. It's a code change (restoring regression), not driven by a
failing test but driven by the design's correctness requirement.

### SPEC count (after this pass)

- [code] 12: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1
- [done] 1: DSFSTG-4
- [no-code] 5: DSAMDR-1, DSAMDR-2, DSFRSH-1, DSFRSH-2, DSCYCL-1
- REMOVED 3: DSDISP-1, DSBNDY-1, DSLEGC-1

### Requirement coverage (all 15 current requirements)

- RQRESU-1: DSRHYD-1
- RQRESU-2: DSRHYD-1, DSRHYD-2
- RQRESU-3: DSSKIP-1, DSDSPK-1
- RQRESU-4: DSRHYD-1, DSSKIP-1, DSDSPK-1, DSCYCL-1
- RQFROM-1: DSFSTG-1, DSFSTG-3
- RQFROM-2: DSFSTG-1, DSCYCL-1
- RQFROM-3: DSFSTG-2, DSCYCL-1
- RQFROM-4: DSFSTG-4[done]
- RQLOOP-1: DSITER-1, DSCMBR-1, DSCYCL-1
- RQPATH-1: DSENTR-1, DSENTR-2, DSCYCL-1
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1
- RQADR-2: DSAMDR-2
- RQHYDR-1: DSRHYD-1, DSDLGT-1

### Key design decisions (unchanged)

- Gap 11: resume_mode=false immediately when skip_until_stage cleared (DSFSTG-3[code])
- Gap 12: --from-stage guard restored before auto-resume (DSFSTG-4[done], step still present)
- Gap 7: _cd_iter > 0 guard in _cycle_dispatch must be removed
- Gap 8: auto-resume symlink check for per-run layout (DSENTR-2[code])
- Gap 9: _cycle_dispatch resume_first_iter=true flag (DSCMBR-1[code])
