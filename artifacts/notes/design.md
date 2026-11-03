# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Thirteenth pass — complete redesign of SPEC IDs, evidence, and covers

### Findings addressed this pass (thirteenth)

All 35 design-gate findings from the previous submission addressed:

1. **All SPECs renamed from SPEC-N to descriptive IDs** (findings 6–19): RHYD-1/2, FSTG-1/2, AMDR-1/2, ITER-1, SKIP-1, ENTR-1, FRSH-1/2, BNDY-1, DLGT-1, CYCL-1. No REMOVED lines needed.

2. **Evidence changed from line numbers to exact text** (findings 1–5):
   - SKIP-1/FRSH-2: `core/pipeline/runner.sh:"When resuming, skip stages already marked complete unless --from-stage overrides"`
   - FRSH-1: `core/state/resume.sh:"get_resume_recommendation"` + `core/pipeline/runner.sh:"if ! $resume_mode; then"`

3. **covers: fields changed from R-N to actual requirement IDs** (findings 20–35): All 16 requirements (RESU-1 through ORDE-1) now appear in at least one SPEC's covers field.

### Requirement → SPEC mapping (thirteenth pass)

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

### What build must still do

| Step | What | Files |
|------|------|-------|
| 1 | Amend ADR-006 step 3.6 + ordering constraint + test names | docs/adr/ADR-006-resume-contract.md |
| 2 | Amend ADR-050 §6 boundary note | docs/adr/ADR-050-prior-work-reuse-contract.md |
| 5 | Add DLGT-1 sentinel-mock delegation test | tests/unit/hydrate-stage-test.sh |
| 6 | Add _ZBUILD_RESUME_ACTIVE guard to cycle-orchestrator.sh | core/pipeline/cycle-orchestrator.sh |
| 9 | Add export _ZBUILD_RESUME_ACTIVE=true before cycle_orchestrator_run | tests/integration/resume-loop-state-test.sh |
| 10 | Retag to CYCL-1; fix grep-c; add AMDR-1/AMDR-2 ADR greps; remove stale block | tests/integration/resume-rehydrate-test.sh |
| 11 | Retag CYCL-1; change FSTG-2 assert to "has no restorable primary artifact" | tests/integration/from-stage-rehydrate-test.sh |

### Implementation verified

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- `if ! $resume_mode; then` at runner.sh:2194 (fresh-run branch) ✓
- comment "When resuming, skip stages already marked complete unless --from-stage overrides" at runner.sh:3895 ✓
- `get_resume_recommendation` in core/state/resume.sh ✓ (no-state-file → fresh_start at line 247)
