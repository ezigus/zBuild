# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Seventeenth pass — SKIP-1 narrowed; FRSH-1 → [no-code]

### Root cause of sixteenth-pass failure (design finding 2)

The design failed on one finding:

**DONE_WRONG**: SKIP-1[done] — "skips any stage with stage_statuses[s]=='complete' during resume" overclaims. The checker read runner.sh lines 3895-3900 and saw the complete-stage branch contains additional conditional logic:
- `if [[ "$stage_status" == "complete" ]]; then` → then `# #507: if the primary artifact has gone missing`
- artifact-present path: `continue` (skip) ✓
- artifact-absent path: `return 1` (exit 1) — NOT a skip

So the SPEC that says "skips any stage" is wrong when the artifact is absent; the code exits 1 there.

### Changes in seventeenth pass

1. **SKIP-1**: Narrowed claim from "skips any stage" to "skips (via `continue`) a complete stage whose primary artifact is present … SKIP-1 describes the artifact-present path only; absent-artifact path covered by RHYD-2." Same evidence text. The evidence at runner.sh:3895 is `"When resuming, skip stages already marked complete unless --from-stage overrides"` — lines 3924-3925 after the artifact check do `info "Skipping already-complete stage" / continue`.

2. **FRSH-1**: Also changed from [done] → [no-code] as planned in the 16th pass notes (had not been saved to design-draft.md). Evidence was wrong (line 2194 `if ! $resume_mode; then` proves fresh run_id creation, not "no rehydration"). Now [no-code] with TESTFILES entry in resume-rehydrate-test.sh. Step 10 updated to add item (5): [#1805/FRSH-1] assertion in --no-resume sub-case.

### Implementation state (verified against worktree)

- `_artifact_persist_put_back` in artifact-persist.sh ✓
- `_artifact_persist_restore` in artifact-persist.sh ✓
- `_runner_resume_rehydrate` at runner.sh:1707, called at runner.sh:2859 ✓
- `export _ZBUILD_RESUME_ACTIVE=true` at runner.sh:2862 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- In-loop exit-1 for missing artifacts at runner.sh:3920 (ADR-006 §3.6 comment) ✓
- comment "When resuming, skip stages already marked complete…" at runner.sh:3895 ✓
- `if $resume_mode; then` at runner.sh:2845 gates the entire rehydration block ✓
- `get_resume_recommendation` in core/state/resume.sh ✓

### Still NOT fixed in code (requires build stage)

- `_cycle_orchestrator_run_body` reads `current_iter` unconditionally — guard with `_ZBUILD_RESUME_ACTIVE` needed (step 6)
- resume-loop-state-test.sh needs `export _ZBUILD_RESUME_ACTIVE=true` before `cycle_orchestrator_run` call (step 9)

### SPEC summary (seventeenth pass)

| SPEC | Classification | Change from 16th |
|------|---------------|-----------------|
| RHYD-1, RHYD-2 | [code] | — |
| FSTG-1, FSTG-2 | [code] | — |
| AMDR-1, AMDR-2 | [no-code] | — |
| ITER-1 | [code] | — |
| SKIP-1 | [done] | claim narrowed to artifact-present path only |
| ENTR-1 | [code] | — |
| FRSH-1 | [no-code] | was [done] with wrong evidence → [no-code], TESTFILES added |
| FRSH-2 | [done] | — |
| BNDY-1 | [no-code] | — |
| DLGT-1 | [code] | — |
| CYCL-1 | [no-code] | — |

**Counts: 7 [code], 1 [done], 5 [no-code], 0 REMOVED**

### Requirement → SPEC mapping

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

### issue-acceptance findings 3/4

These are build-stage concerns: the design correctly specifies AMDR-1/2 as [no-code] SPECs with tests in resume-rehydrate-test.sh. Those tests grep for the amendment text in the ADR files and fail if the amendments aren't written. The design cannot show diff content it doesn't produce.
