# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Thirtieth pass — no changes required

### Issue-acceptance findings assessed (this pass)

**Issue-acceptance NOT SURE R-5 (ADR-006 step 3.6):**
"what would settle it: a test that fails when it is not met" — the design already specifies
AMDR-1[no-code] with a test in `resume-rehydrate-test.sh` that greps for the step 3.6 amendment
text. If the ADR file does not contain the required text, that test fails. This is a build-stage
gap (the amendment must actually be written to the file), not a design gap. No design change needed.

**Issue-acceptance NOT SURE R-6 (ADR-050 §6 boundary note):**
Same resolution. AMDR-2[no-code] specifies a test that greps for the boundary note text and the
Enforced by citations (widened in the twenty-ninth pass to include FRSH-2 and ENTR-1 citations).
If absent, the test fails. No design change needed.

**Issue-acceptance first point (dispatch-unit loop regression on non-resume paths):**
The design specifies FRSH-1[no-code] and FRSH-2[no-code] covering GUAR-1 and GUAR-2. The
skip-on-complete guards are conditioned on `$resume_mode`; fresh runs never activate them. This is
a build/test concern, not a design gap. No design change needed.

### Design is correct and complete

The design file at `/home/runner/work/_temp/zbuild-state/artifacts/design-draft.md` is current
and matches the LATEST DESIGN exactly. All 17 requirements are covered. No open findings require
design changes.

### SPEC summary (unchanged from twenty-ninth pass)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 ORDE-1 |
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

## Previous pass notes (twenty-ninth pass — AMDR-2 widened)

**Design finding 1**: AMDR-2 stated the boundary note for ADR-050 §6 but did not specify updating
§6's "Enforced by" entry. The existing entry cites only `resume-default-test.sh R5–R11`. CLAUDE.md
requires every live ADR statement to have its test named in Enforced by. AMDR-2 now explicitly
requires adding citations for FRSH-2 (resume-rehydrate-test.sh, new-run side) and ENTR-1
(resume-entry-points-test.sh, resume side). Step 2 updated to match.

## Previous pass notes (twenty-eighth pass — SKIP-1[code], FRSH-2[no-code], LEGC-1 REMOVED)

The dispatch-unit skip-on-complete guards are at:
- runner.sh:3442 (`cycle:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- runner.sh:3728 (`stage:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`

Both were added by this branch. The only pre-existing skip guard is in the legacy linear loop
at runner.sh:3895, which DISP-1 forbids using as evidence.

SKIP-1 changed to [code] (dispatch-unit guard is new code from this branch).
FRSH-2 changed to [no-code] (pre-change code had no dispatch-unit guard at all, so test passes
on pre-change code too — cannot be [code]).
LEGC-1 REMOVED (DISP-1 covered by SKIP-1[code]).
