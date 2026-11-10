# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Fifty-second pass — confirming design is correct; answering open findings

### Open findings being answered this pass

**design finding 1** — checker said DSFSTG-4[done] evidence not in base code.
Verification: grepped `/home/runner/work/_temp/zbuild-state/base-code/core/pipeline/runner.sh` for "from-stage is only valid"; returned:
- line 1736: `# --from-stage is only valid in resume mode`
- line 1738: `error "--from-stage is only valid with --resume"`

The evidence string `--from-stage is only valid with --resume` IS in the base code. DSFSTG-4[done] is correct. Answer: wrong.

**lens-correctness-design finding 1** — not answered in previous pass. The finding says after a targeted cycle clears `skip_until_stage`, `resume_mode` stays `true`, causing the resume skip guard to activate for subsequent leaf stages.

This is Gap 11 in the architectural decision. The design already addresses it:
- Context/gaps Gap 11 documents the problem and fix
- Decision paragraph requires `{ skip_until_stage=""; resume_mode=false; }` in both arms
- DSFSTG-3[code] provides the observable test (3-unit [intake, cyc, verify]; verify marked complete; combined --resume --from-stage cyc; asserts verify still dispatches)
- Finding 30 and Finding 31 in the design document the gap and fix

Answer: done — no design change needed.

### No design changes required

The design file is complete and correct. All findings answered.

### SPEC count

- [code] 12: DSRHYD-1, DSRHYD-2, DSFSTG-1, DSFSTG-2, DSFSTG-3, DSITER-1, DSCMBR-1, DSSKIP-1, DSDSPK-1, DSENTR-1, DSENTR-2, DSDLGT-1
- [no-code] 5: DSAMDR-1, DSAMDR-2, DSFRSH-1, DSFRSH-2, DSCYCL-1
- [done] 1: DSFSTG-4 — evidence: core/pipeline/runner.sh:"--from-stage is only valid with --resume" (confirmed at line 1738 of base code)
- REMOVED 3: DSDISP-1, DSBNDY-1, DSLEGC-1

### Requirement coverage (all 17 covered)

- RQRESU-1: DSRHYD-1
- RQRESU-2: DSRHYD-1, DSRHYD-2
- RQRESU-3: DSSKIP-1, DSDSPK-1
- RQRESU-4: DSRHYD-1, DSSKIP-1, DSDSPK-1
- RQFROM-1: DSFSTG-1, DSFSTG-3
- RQFROM-2: DSFSTG-1
- RQFROM-3: DSFSTG-2
- RQFROM-4: DSFSTG-4[done] — base-code guard fires at argument-parse time before auto-resume
- RQTEST-1: DSCYCL-1
- RQDISP-1: DSSKIP-1
- RQADR-1: DSAMDR-1
- RQADR-2: DSAMDR-2
- RQHYDR-1: DSRHYD-1, DSDLGT-1
- RQLOOP-1: DSITER-1, DSCMBR-1
- RQPATH-1: DSENTR-1, DSENTR-2
- RQGUAR-1: DSFRSH-1
- RQGUAR-2: DSFRSH-2
