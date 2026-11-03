# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Sixteenth pass — FRSH-1 → [no-code]; DLGT-1 description rewritten

### Root cause of fifteenth-pass failure

The design failed with two LLM coverage findings (from coverage.sh _design_coverage):
1. **OUTSIDE** (→ "the issue does not ask for this, or the design gets it wrong"): omitted
2. **DONE_WRONG** (→ "marked [done], but the code its evidence points at does not do it"): omitted

Both said "omitted" because the LLM wrote `OUTSIDE: omitted` and `DONE_WRONG: omitted`
in its structured answer. The `_dcov_list` function does not filter "omitted" (only "none"),
so both were recorded as findings.

### Root cause: FRSH-1

Both findings trace to **FRSH-1[done]**:

**DONE_WRONG**: FRSH-1's evidence `core/pipeline/runner.sh:"if ! $resume_mode; then"` is
at line 2194. `_dcov_done_evidence` shows the LLM lines 2189–2199. That block creates a
fresh run_id (`_raw_run_id`, `_runner_run_id`). It has nothing to do with rehydration.
The LLM correctly sees: "this code creates a run_id, not proves 'no rehydration'."

**OUTSIDE**: FRSH-1 said "A run with no prior state file proceeds as a fresh start with
no rehydration." GUAR-1 requires "A run with no prior state file behaves exactly as today."
"No rehydration" is an implementation-specific narrowing — not the full behavior GUAR-1
asks for. The LLM flags this as "the design gets it wrong."

Secondary fix: DLGT-1's description was rewritten from implementation-focused ("delegates
its copy-back operation") to outcome-focused ("resume and hydrate both call the same function,
so artifacts appear at the same filesystem paths") = what HYDR-1 actually requires.

### Changes in sixteenth pass

1. **FRSH-1**: [done] → [no-code]
   - Old: "A run with no prior state file proceeds as a fresh start with no rehydration"
     evidence: `resume.sh:"get_resume_recommendation"` `runner.sh:"if ! $resume_mode; then"`
   - New: "A run with no prior interrupted state (no --resume flag and no status=interrupted
     state file) behaves exactly as before this change: all stages dispatch from stage 1,
     no stage is skipped due to prior state, and no artifacts from a prior run appear in
     ZBUILD_ARTIFACT_DIR covers: GUAR-1"
   - TESTFILES: FRSH-1: tests/integration/resume-rehydrate-test.sh (added)
   - Step 10 item (7) added: assertion tagged [#1805/FRSH-1] in the --no-resume sub-case

2. **DLGT-1**: description rewritten from implementation to outcome:
   - Old: "The hydrate plugin's hydrate_run delegates its copy-back operation to
     _artifact_persist_put_back (not the old inline _hydrate_put_back)"
   - New: "Resume rehydration and the hydrate plugin both call _artifact_persist_put_back, so
     artifacts placed by the resume path appear at the same filesystem paths as those a hydrate
     run would produce; a sentinel override of _artifact_persist_put_back in hydrate-stage-test.sh
     confirms hydrate_run reaches the shared function and fails when plugin.sh is reverted
     to calling _hydrate_put_back inline covers: HYDR-1"

### Acceptance classification summary (sixteenth pass)

| SPEC | Classification | Change from 15th |
|------|---------------|-----------------|
| RHYD-1, RHYD-2 | [code] | — |
| FSTG-1, FSTG-2 | [code] | — |
| AMDR-1, AMDR-2 | [no-code] | — |
| ITER-1 | [code] | — |
| SKIP-1 | [done] | — |
| ENTR-1 | [code] | — |
| FRSH-1 | [no-code] | was [done] → evidence removed, TESTFILES added |
| FRSH-2 | [done] | — |
| BNDY-1 | [no-code] | — |
| DLGT-1 | [code] | description rewritten (outcome focus) |
| CYCL-1 | [no-code] | — |

### SPEC counts: 7 [code], 1 [done], 5 [no-code], 0 REMOVED

### Implementation state (verified)

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- `_cycle_orchestrator_run_body` guard at cycle-orchestrator.sh:2326 ✓
- `resume-loop-state-test.sh` exports `_ZBUILD_RESUME_ACTIVE=true` at line 82 ✓
- comment "When resuming, skip stages already marked complete…" at runner.sh:3895 ✓
- `get_resume_recommendation` in core/state/resume.sh ✓
- `if ! $resume_mode; then` at runner.sh:2194 (fresh-run run_id setup) ✓

### Requirement → SPEC mapping (unchanged)

| Requirement | SPEC(s) |
|-------------|---------|
| RESU-1 | RHYD-1 |
| RESU-2 | RHYD-1, RHYD-2 |
| RESU-3 | SKIP-1 |
| RESU-4 | RHYD-1, SKIP-1 |
| FROM-1 | FSTG-1 |
| FROM-2 | FSTG-1 |
| FROM-3 | FSTG-2 |
| LOOP-1 | ITER-1 |
| PATH-1 | ENTR-1 |
| GUAR-1 | FRSH-1 |
| GUAR-2 | FRSH-2 |
| ADR-1 | AMDR-1 |
| ADR-2 | AMDR-2, BNDY-1 |
| HYDR-1 | RHYD-1, DLGT-1 |
| TEST-1 | CYCL-1 |
| ORDE-1 | AMDR-1 |

---

## Previous: Fifteenth pass — AMDR-1/AMDR-2/BNDY-1/CYCL-1 → [no-code]

The 15th pass changed AMDR-1/2/BNDY-1/CYCL-1 from [done] to [no-code] because those
evidence texts were added by this branch. FRSH-1 stayed [done] — that was the mistake.

The [done] evidence at line 2194 of runner.sh proved only fresh run_id creation, NOT
"no rehydration". GUAR-1 ("behaves exactly as today") is broader than "no rehydration."
