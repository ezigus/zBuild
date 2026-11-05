# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Twenty-sixth pass — LEGC-1 Then: line stripped of implementation detail

### Root cause of twenty-sixth-pass need for change

**design finding 1 (this pass)**: LEGC-1's Then: line said "No stage.start event is emitted for that stage (behavior governed by runner.sh:3895-3927, not by legacy-DoNotUse dispatch)". The checker flagged this because:
1. It names specific implementation line numbers as the governing location — that is not an observable behavior.
2. Those line numbers are wrong anyway: 3895-3927 is the post-dispatch RC-narrowing/verdict block; the actual skip-on-complete guard is at 3723-3751.

Fix: removed the parenthetical. LEGC-1's Then: now says only "No stage.start event is emitted for that stage" — the observable outcome. Evidence text `core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"` remains valid (confirmed at runner.sh:3895).

No other changes.

### Root cause of twenty-fifth-pass need for change

Design checker found two issues in the twenty-fourth-pass design-draft:

**design finding 1**: BNDY-1 describes what a file contains ("resume-rehydrate-test.sh
contains both a resume-side assertion and a fresh-run sub-case"), which no test can
prove. The checker rule: describe the behaviour someone could observe, not what a file
contains.

**design finding 2**: DISP-1 (old SPEC id, renamed DSPK-1 in pass 24 to avoid
collision with the new requirement id DISP-1) disappeared from the acceptance block
without a REMOVED tombstone. Rule: "A SPEC you drop gets its own line:
REMOVED: <id> — <why>."

### Changes in this pass

**Fix for design finding 2 — add REMOVED: DISP-1 tombstone**

Add after LEGC-1[done]:
```
REMOVED: DISP-1 — id collides with requirement code DISP-1 added by intake; the SPEC is preserved as DSPK-1
```

**Fix for design finding 1 — REMOVE BNDY-1**

BNDY-1[no-code] described "resume-rehydrate-test.sh contains both..." — that is a
file-content assertion, which no test can prove. I examined whether to rewrite it as
an observable behaviour, but:

- Any single-When/Then form for the boundary would duplicate either RHYD-1 (resume
  side) or FRSH-1/FRSH-2 (new-run side), which already cover both sides.
- ADR-2 says "amend ADR-050 §6 … with a test pinning each side." The amendment is
  covered by AMDR-2[no-code]. The "test pinning each side" is satisfied by the
  [code] SPEC RHYD-1 (covers the resume side, tagged RESU-1/RESU-2/RESU-4/HYDR-1)
  and FRSH-1[no-code] (covers the new-run side, tagged GUAR-1) already in the design.
  AMDR-2 alone is sufficient to cover ADR-2.

Therefore BNDY-1 is REMOVED. Add tombstone:
```
REMOVED: BNDY-1 — described file contents ("contains both…"), which no test can prove;
ADR-2 is fully covered by AMDR-2; the two sides are pinned by RHYD-1 (resume) and FRSH-1 (new-run)
```

**Step 10 update**: the reference to "BNDY-1 runner invocation" becomes "fresh-run
sub-case" (the sub-case is still needed for FRSH-1).

**TESTFILES update**: remove the `BNDY-1: tests/integration/resume-rehydrate-test.sh` line.

**Finding 3 update**: ADR-2: AMDR-2 only (BNDY-1 removed).

**Finding counts update**: [no-code] was 5, now 4. REMOVED count: 2.

### SPEC summary (twenty-fifth pass)

| SPEC | Classification | Covers |
|------|---------------|--------|
| RHYD-1 | [code] | RESU-1 RESU-2 RESU-4 HYDR-1 |
| RHYD-2 | [code] | RESU-2 |
| FSTG-1 | [code] | FROM-1 FROM-2 |
| FSTG-2 | [code] | FROM-3 |
| AMDR-1 | [no-code] | ADR-1 ORDE-1 |
| AMDR-2 | [no-code] | ADR-2 |
| ITER-1 | [code] | LOOP-1 |
| SKIP-1 | [done] | RESU-3 RESU-4 |
| DSPK-1 | [code] | RESU-3 RESU-4 |
| ENTR-1 | [code] | PATH-1 |
| FRSH-1 | [no-code] | GUAR-1 |
| FRSH-2 | [done] | GUAR-2 |
| DLGT-1 | [code] | HYDR-1 |
| CYCL-1 | [no-code] | TEST-1 |
| LEGC-1 | [done] | DISP-1 |
| REMOVED: DISP-1 | — | id collision with requirement DISP-1; preserved as DSPK-1 |
| REMOVED: BNDY-1 | — | described file contents; ADR-2 covered by AMDR-2 |

**Counts: 8 [code], 3 [done], 4 [no-code], 2 REMOVED**

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
| DISP-1 | LEGC-1 |

### Implementation state (verified — no code changes in this pass)

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- In-loop exit-1 for missing artifacts at runner.sh:3920 (ADR-006 §3.6 comment) ✓
- comment "When resuming, skip stages already marked complete…" at runner.sh:3895 ✓
- `if $resume_mode; then` at runner.sh:2845 gates entire rehydration block ✓
- Stage k dispatch: skip guard only for `stage_status == "complete"`; stage k falls
  through to `eb_emit_event "stage.start"` at runner.sh:3937 ✓

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with
  `_ZBUILD_RESUME_ACTIVE` needed (step 6)
- resume-loop-state-test.sh needs `export _ZBUILD_RESUME_ACTIVE=true` before
  `cycle_orchestrator_run` call (step 9)
