# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fifty-fifth pass — fixing DSFSTG-3 Given inconsistency with DSFSTG-4

### What changed this pass

The design was "unusable" because DSFSTG-3's Given said "the runner is invoked with both
auto-resume active and --from-stage <s>". DSFSTG-4 says that --from-stage without explicit
--resume exits 1 BEFORE auto-resume runs (the guard fires before state is read). So the
DSFSTG-3 scenario — reaching the dispatch loop in combined mode — is unreachable when the
Given only says "auto-resume active": DSFSTG-4's guard fires first and exits.

**Fix:** Changed DSFSTG-3's Given from "auto-resume active and --from-stage <s>" to
"explicit --resume and --from-stage <s>". Also updated the corresponding step description
for the DSFSTG-3 test sub-case in from-stage-rehydrate-test.sh to say "explicit --resume
and --from-stage cyc" instead of "auto-resume active and --from-stage cyc".

No other changes: the design file already had (from the fifty-fourth pass):
- DSFSTG-4[code] covering RQFROM-4 ✓
- DSCYCL-1 covers: RQRESU-4 RQLOOP-1 RQFROM-2 RQFROM-3 RQPATH-1 (not RQTEST-1) ✓
- DSSKIP-1 covers: RQRESU-3 RQRESU-4 (no RQDISP-1) ✓
- Gap 12 documented and step for it ✓

### SPEC count (after this pass)

- [code] 14: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1, (wait: that's 13 — let
  me recount)
  Actually: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSFSTG-4, DSITER-1,
  DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1 = 13 [code] SPECs
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
- RQFROM-4: DSFSTG-4[code]
- RQLOOP-1: DSITER-1, DSCMBR-1, DSCYCL-1
- RQPATH-1: DSENTR-1, DSENTR-2, DSCYCL-1
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
- RQADR-1: DSAMDR-1
- RQADR-2: DSAMDR-2
- RQHYDR-1: DSRHYD-1, DSDLGT-1

### Key design decisions (unchanged from previous passes)

- Gap 11: resume_mode=false immediately when skip_until_stage cleared, preventing resume
  skip guard from suppressing stages after <s> in combined --resume --from-stage mode.
  Covered by DSFSTG-3[code].
- Gap 12: --from-stage guard must run BEFORE auto-resume check, so explicit --resume is
  required even when auto-resume would otherwise fire. Covered by DSFSTG-4[code].
- Gap 7: _cd_iter > 0 guard in _cycle_dispatch is WRONG; must be removed. Fresh runs
  emit no stage.start for cycle members. Golden files must be preserved.
- Gap 8: auto-resume symlink check for per-run layout. Covered by DSENTR-2[code].
- Gap 9: _cycle_dispatch resume_first_iter=true flag for skipping complete members in
  the interrupted iteration. Covered by DSCMBR-1[code].
