# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Eleventh pass — fixing three design-gate findings

### Findings addressed this pass (eleventh)

**design finding 1** — R-9 not covered: SPEC-7 covers loop-state side of R-9; SPEC-9 covers "all three entry paths invoke _runner_resume_rehydrate" which is exactly R-9 ("every way to resume finds the interrupted run's state and behaves as R-1"), but SPEC-9 named only R-12. Fix: add `R-9` to SPEC-9 covers. SPEC-7 retains R-9 too.

**design finding 2** — R-10 not covered: SPEC-3 named R-10 but covers --from-stage dispatch. SPEC-10[done] covers the no-prior-state → fresh-start path (resume.sh:247) which is exactly R-10. Fix: add `R-10` to SPEC-10 covers.

**design finding 3** — R-12 not covered: SPEC-9 named R-12 but only checks the call path. R-12 requires amending ADR-006. SPEC-5 verifies the amendment via grep assertions. Fix: add `R-12` to SPEC-5 covers. SPEC-9 retains R-12 too (three-entry-path test is the ADR's named enforcing test).

### Summary of changes from tenth to eleventh pass

| SPEC | Field changed | Old value | New value |
|------|--------------|-----------|-----------|
| SPEC-5 | covers | R-5 | R-5 R-12 |
| SPEC-9 | covers | R-12 | R-9 R-12 |
| SPEC-10 | covers | R-13 | R-10 R-13 |

### issue-acceptance findings (not design changes)

- Finding 3: ADR-006 amendment not verifiable from diff — build concern; SPEC-5 already specifies grep assertion in resume-rehydrate-test.sh
- Finding 4: ADR-050 amendment not verifiable from diff — build concern; SPEC-6 already specifies grep assertion in resume-rehydrate-test.sh

### Previously verified (still holds from tenth pass)

- runner.sh:3896 = `if $resume_mode && [[ -z "$skip_until_stage" ]]; then` (SPEC-8, SPEC-11 evidence)
- runner.sh:3899 = `if [[ "$stage_status" == "complete" ]]; then` (SPEC-8 evidence)
- resume.sh:247 = no-state-file → fresh_start branch (SPEC-10 evidence)
- `_artifact_persist_put_back` at artifact-persist.sh:638 ✓
- `_artifact_persist_restore` at artifact-persist.sh:568 ✓
- `_runner_resume_rehydrate` at runner.sh:1702 ✓, called at runner.sh:2838 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- SPEC-7: NEGCTL PASS ✓
- SPEC-9: NEGCTL PASS ✓
- SPEC-13: NEGCTL PASS ✓

### What build must still do

| Step | What | Files |
|------|------|-------|
| 1 | Amend ADR-006 step 3.6 + SPEC-5 grep assertions | docs/adr/ADR-006-resume-contract.md, tests/integration/resume-rehydrate-test.sh |
| 2 | Amend ADR-050 §6 boundary note + SPEC-6 grep assertion | docs/adr/ADR-050-prior-work-reuse-contract.md, tests/integration/resume-rehydrate-test.sh |
| 5(b) | Add SPEC-13 sentinel-mock delegation test | tests/unit/hydrate-stage-test.sh |
| 6 | Add _ZBUILD_RESUME_ACTIVE guard to cycle-orchestrator.sh | core/pipeline/cycle-orchestrator.sh |
| 7 | Export _ZBUILD_RESUME_ACTIVE=true in runner.sh after line 2838 | core/pipeline/runner.sh |
| 9 | Add export _ZBUILD_RESUME_ACTIVE=true before cycle_orchestrator_run | tests/integration/resume-loop-state-test.sh |
| 10 | Retag SPEC-14; fix grep-c; add SPEC-5/SPEC-6 ADR greps; remove stale SPEC-12 block | tests/integration/resume-rehydrate-test.sh |
| 11(2)+(3) | Retag SPEC-14; change SPEC-4 assert to "has no restorable primary artifact" | tests/integration/from-stage-rehydrate-test.sh |
