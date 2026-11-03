# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Refinement complete (eighth pass)

### Finding addressed this pass: SPEC-4 tautology

**acceptance-gate finding 1:** SPEC-4's test already passes on old code.

Root cause verified by reading from-stage-rehydrate-test.sh:154–225 and runner.sh:1727–1756:

The test has three assertions under SPEC-4:
1. `assert_eq "1" "$_s4_rc"` — old code also exits 1 (for different reasons)
2. `assert_contains "$_s4_stderr" "intake"` — old code emits "intake" in stderr too
3. `assert_eq "0" "$_s4_any_starts"` — old code also emits no stage.start before exiting

The ONLY phrase that discriminates new from old code is from `_runner_from_stage_preflight` at runner.sh:1751:
```
"error: --from-stage '$_fsp_from_stage': stage '$_fsp_s' has no restorable primary artifact"
```

Key substring: **"has no restorable primary artifact"** — absent from old code entirely.

Fixes applied in design (eighth pass):
- SPEC-4 rewritten to require this specific phrase in stderr (not just "intake")
- Step 11 updated: added item (3) — change assert_contains for SPEC-4 from "intake" to "has no restorable primary artifact"
- Finding 12 added documenting the tautology and its fix

### SPEC-1/SPEC-2/SPEC-3 not_passing_at_head (issue-acceptance finding)

These fail because the setup step `assert_fail "[#1805/SPEC-1] setup: snapshot to state branch failed"` fails — `_artifact_persist_snapshot` fails in the test environment. Build-stage concern, not a design change. Finding 13 added.

### issue-acceptance findings 7 and 8

Finding 7 (R-9/SPEC-7 loop iter): SPEC-7 NEGCTL PASS — the uncertainty is a build-stage concern. Finding 14 added.
Finding 8 (R-5/R-6 ADR amendments): ADR diffs not visible to issue-acceptance. Steps 1 and 2 correctly specify the amendments. Finding 15 added.

---

## What still needs to be done by the build

| Step | What | Files |
|------|------|-------|
| 5(b) | Add SPEC-13 sentinel-mock delegation test | tests/unit/hydrate-stage-test.sh |
| 6 | Add _ZBUILD_RESUME_ACTIVE guard to cycle-orchestrator.sh | core/pipeline/cycle-orchestrator.sh |
| 7 | Export _ZBUILD_RESUME_ACTIVE=true in runner.sh after line 2838 | core/pipeline/runner.sh |
| 9 | Add export _ZBUILD_RESUME_ACTIVE=true before cycle_orchestrator_run at line 76 | tests/integration/resume-loop-state-test.sh |
| 10 item (4) | Retag assert_contains in SPEC-13 section (line ~638) as [#1805/SPEC-14] | tests/integration/resume-rehydrate-test.sh |
| 11 items (2)+(3) | Retag assert_contains (SPEC-14); change SPEC-4 assert_contains to "has no restorable primary artifact" | tests/integration/from-stage-rehydrate-test.sh |
| SPEC-1/2/3 setup | Fix _artifact_persist_snapshot state branch write in test environments | tests/integration/resume-rehydrate-test.sh, tests/integration/from-stage-rehydrate-test.sh |

---

## Evidence verified (eighth pass)

- `_runner_from_stage_preflight` at runner.sh:1727–1756: error message at runner.sh:1751: "error: --from-stage '...': stage '...' has no restorable primary artifact" ✓
- from-stage-rehydrate-test.sh:214-216: `assert_contains ... "$_s4_stderr" "intake"` — tautological ✓

## Previously verified (still holds)

- `_artifact_persist_put_back` at artifact-persist.sh:638 ✓
- `_artifact_persist_restore` at artifact-persist.sh:568 ✓
- `_runner_resume_rehydrate` at runner.sh:1702 ✓, called at runner.sh:2838 ✓
- `plugins/tool/hydrate/plugin.sh` line 162 calls `_artifact_persist_put_back` ✓
- SPEC-8[done]: runner.sh:3808 = `if $resume_mode && [[ -z "$skip_until_stage" ]]` ✓
- SPEC-10[done]: resume.sh:247 = no-state → fresh_start branch ✓
- SPEC-11[done]: runner.sh:3808 same line (resume_mode=false for new runs) ✓
- artifact-snapshot-coverage.yaml line 17: `type: cycle` ✓
- SPEC-7: NEGCTL PASS ✓
- SPEC-9: NEGCTL PASS ✓
- SPEC-13: NEGCTL PASS ✓
