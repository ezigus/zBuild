# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Twenty-ninth pass — AMDR-2 widened to cover §6 Enforced by citations

### Root cause of twenty-ninth-pass need for change

**Design finding 1**: AMDR-2 stated the boundary note for ADR-050 §6 but did not specify updating
§6's "Enforced by" entry. The existing entry cites only `resume-default-test.sh R5–R11`. CLAUDE.md
requires every live ADR statement to have its test named in Enforced by. AMDR-2 now explicitly
requires adding citations for FRSH-2 (resume-rehydrate-test.sh, new-run side) and ENTR-1
(resume-entry-points-test.sh, resume side). Step 2 updated to match.

## Status: Twenty-eighth pass — SKIP-1[code], FRSH-2[no-code], LEGC-1 REMOVED

### Root cause of twenty-eighth-pass need for change

**Design findings 1–3**: SKIP-1[done], FRSH-2[done], and LEGC-1[done] all cited evidence
`core/pipeline/runner.sh:"ADR-006 §3.6 / #1805 (SPEC-1): resume mode — skip stages"`
at runner.sh:3724. That text was **added by this branch** (dispatch-unit path). The design
checker correctly rejected it as not being pre-change code.

### Key facts (verified)

The dispatch-unit skip-on-complete guards are at:
- runner.sh:3442 (`cycle:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- runner.sh:3728 (`stage:*` arm): `if $resume_mode && [[ -z "$skip_until_stage" ]]`

Both were added by this branch. The only pre-existing skip guard is in the legacy linear loop
at runner.sh:3895 (`"When resuming, skip stages already marked complete unless --from-stage overrides"`),
which DISP-1 forbids using as evidence.

### Changes in this pass

**SKIP-1**: `[done]` → `[code]`
- The dispatch-unit skip-on-complete guard is new code from this branch
- Test fails on pre-change code: cyclic templates use the dispatch-unit loop; before this branch,
  no skip guard existed there, so stage.start WOULD be emitted for complete stages during resume
- Test passes after: guard active, no stage.start for complete stages
- DISP-1 added to `covers:` → LEGC-1 can be removed

**FRSH-2**: `[done]` → `[no-code]`
- The skip guard is conditioned on `$resume_mode` (false for fresh runs)
- Pre-change code had no dispatch-unit skip guard at all → fresh runs never skipped → test
  would PASS on pre-change code → cannot be [code]
- [no-code]: test need not fail before, just pass after (confirms conditional guard works)
- Given/When/Then kept: scenario has prior run state present but no --resume flag

**LEGC-1**: `[done]` → `REMOVED: LEGC-1`
- Was meant to prove "no [done] SPEC cites legacy-loop evidence"
- DISP-1 is now fully covered by SKIP-1[code], which tests the dispatch-unit path directly
- Redundant; removed with tombstone to prevent id reuse

**TESTFILES updated**: Added `SKIP-1: tests/integration/resume-rehydrate-test.sh` and
`FRSH-2: tests/integration/resume-rehydrate-test.sh`; removed LEGC-1 entry.

**Step 10 updated**: Added items (7) [#1805/FRSH-2] assertion and (8) [#1805/SKIP-1] assertion.

### SPEC summary (twenty-eighth pass)

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
| REMOVED: DISP-1 | — | id collision with requirement DISP-1; preserved as DSPK-1 |
| REMOVED: BNDY-1 | — | described file contents; ADR-2 covered by AMDR-2 |
| REMOVED: LEGC-1 | — | DISP-1 covered by SKIP-1[code]; no [done] SPECs remain |

**Counts: 9 [code], 5 [no-code], 0 [done], 3 REMOVED**

### Requirement → SPEC mapping (all 17 covered)

| Requirement | SPEC(s) |
|-------------|---------|
| RESU-1 | RHYD-1 |
| RESU-2 | RHYD-1, RHYD-2 |
| RESU-3 | SKIP-1, DSPK-1 |
| RESU-4 | RHYD-1, SKIP-1, DSPK-1 |
| FROM-1 | FSTG-1 |
| FROM-2 | FSTG-1 |
| FROM-3 | FSTG-2 |
| LOOP-1 | ITER-1 |
| PATH-1 | ENTR-1 |
| GUAR-1 | FRSH-1 |
| GUAR-2 | FRSH-2 |
| ADR-1 | AMDR-1 |
| ADR-2 | AMDR-2 |
| HYDR-1 | RHYD-1, DLGT-1 |
| TEST-1 | CYCL-1 |
| ORDE-1 | AMDR-1 |
| DISP-1 | SKIP-1 |

### Implementation state (verified)

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- In-loop exit-1 for missing artifacts at runner.sh:3920 ✓
- Dispatch-unit skip guard (cycle:*): `if $resume_mode` at runner.sh:3442 ✓
- Dispatch-unit skip guard (stage:*): `if $resume_mode` at runner.sh:3728 ✓
- Stage k dispatch: skip guard only for `stage_status == "complete"`; falls through to stage.start ✓

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with
  `_ZBUILD_RESUME_ACTIVE` needed (step 6)
- resume-loop-state-test.sh needs `export _ZBUILD_RESUME_ACTIVE=true` before
  `cycle_orchestrator_run` call (step 9)

### Design findings answered

- Design finding 1 (SKIP-1 evidence): Fixed — SKIP-1 is now [code]; no evidence field needed
- Design finding 2 (FRSH-2 evidence): Fixed — FRSH-2 is now [no-code]; no evidence field needed
- Design finding 3 (LEGC-1 evidence): Fixed — LEGC-1 REMOVED; DISP-1 covered by SKIP-1[code]
- Issue-acceptance finding 2: Fixed by same changes
- Issue-acceptance finding 3 (ORDE-1): AMDR-1[no-code] records the constraint in ADR-006 and its
  test greps for the constraint text; mechanical enforcement is as strong as possible for a
  scheduling constraint. No design change needed.
