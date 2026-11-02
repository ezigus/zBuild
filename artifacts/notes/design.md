# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Refinement complete (seventh pass)

The sixth-pass design was rejected by the design checker for two missing requirement coverages:
- R-15 ("Tests for R1–R5 must use a cycle") — no SPEC covered it
- R-16 ("A test pins each side.") — no SPEC covered it

The design had erroneously concluded these requirements don't exist (claimed R-1 through R-14 only). They DO exist — the full list is R-1 through R-16.

Fix applied this pass:
- SPEC-14[no-code] added covering R-15: both test files (resume-rehydrate-test.sh, from-stage-rehydrate-test.sh) already have assert_contains checking type:cycle in their SPEC-13 sections (lines 638 and 268 respectively); steps 10 item (4) and 11 item (2) retag them [#1805/SPEC-14].
- SPEC-12 updated to `covers: R-14 R-16`: resume-rehydrate-test.sh has both the resume-side assertions (SPEC-1/SPEC-2) and the fresh-run sub-case (SPEC-12 --no-resume), so one file pins each side.
- artifact-snapshot-coverage.yaml line 17: `type: cycle` confirmed.

---

## Status from sixth pass (unchanged items)

The fifth-pass design was checked. The build ran. The acceptance-summary.txt showed:
- All NEGCTL checks PASS (SPEC-1 through SPEC-9)
- REACHABILITY FAIL: `plugins/tool/hydrate/plugin.sh` — reverting this file leaves no test failing

The issue-acceptance (from the same run) reported 10 requirements not met and 12 tests failing. The test suite failures come from steps 6 and 7 (cycle-orchestrator guard + runner export) not yet being applied by the build.

---

## What changed this pass

### 1. REACHABILITY FAIL root cause identified

`plugins/tool/hydrate/plugin.sh` was changed to call `_artifact_persist_put_back` at line 162 (instead of `_hydrate_put_back`). But `hydrate-stage-test.sh` line 216 calls `_artifact_persist_put_back` DIRECTLY (not through the plugin), so reverting the plugin doesn't break any test.

Fix: add SPEC-13[code] — a sentinel-mock test in `hydrate-stage-test.sh` that overrides `_artifact_persist_put_back` with a sentinel-writing function, calls `hydrate_run`, and asserts the mock was reached. This fails when the plugin is reverted to calling `_hydrate_put_back` inline.

### 2. SPEC-13 repurposed

The original SPEC-13 (covered only non-existent R-15) was already dropped. The new SPEC-13 is: "hydrate_run delegates to _artifact_persist_put_back; sentinel mock test verifies delegation" covering R-7. Added to TESTFILES and WIRING.

### 3. `plugins/tool/hydrate/plugin.sh` added to WIRING

Now WIRING lists: runner.sh, cycle-orchestrator.sh, plugins/tool/hydrate/plugin.sh.

### 4. Step 5 updated

Previously said "redirect direct _hydrate_put_back call at line 216 to _artifact_persist_put_back". Now says: (a) line 216 is already updated — leave as-is; (b) add the sentinel-mock SPEC-13 section.

### 5. Step 10 simplified

Previously had four items; items (1)–(3) are all done, item (4) is unnecessary (SPEC-13 section in resume-rehydrate-test.sh is benign). Step 10 is now a "verify" step confirming the changes are in place.

### 6. Supersedes block cleaned up

Removed entries for `pipeline-resume-test.sh` (artifact pre-write done at line 255) and `hydrate-stage-test.sh` (line 216 redirect done; SPEC-13 handles delegation). Kept the four cycle regression test entries (step 6 still not applied).

---

## What still needs to be done by the build

| Step | What | Files |
|------|------|-------|
| 5(b) | Add SPEC-13 sentinel-mock delegation test | tests/unit/hydrate-stage-test.sh |
| 6 | Add _ZBUILD_RESUME_ACTIVE guard to cycle-orchestrator.sh | core/pipeline/cycle-orchestrator.sh |
| 7 | Export _ZBUILD_RESUME_ACTIVE=true in runner.sh after line 2838 | core/pipeline/runner.sh |
| 9 | Add export _ZBUILD_RESUME_ACTIVE=true before cycle_orchestrator_run at line 76 | tests/integration/resume-loop-state-test.sh |
| 10 item (4) | Retag assert_contains in SPEC-13 section (line ~638) as [#1805/SPEC-14] — do NOT remove | tests/integration/resume-rehydrate-test.sh |
| 11 item (2) | Retag assert_contains in SPEC-13 section (line ~268) as [#1805/SPEC-14] — do NOT remove | tests/integration/from-stage-rehydrate-test.sh |

---

## Evidence verified this pass

- SPEC-8[done]: runner.sh:3808 = `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- SPEC-10[done]: resume.sh:247 = inside get_resume_recommendation, no-state → fresh_start
- SPEC-11[done]: runner.sh:3808 same line (resume_mode=false for new runs → no skip)
- Gap 6 (REACHABILITY FAIL): hydrate plugin line 162 calls `_artifact_persist_put_back` ✓; `_hydrate_put_back` still exists as dead code at lines 64–73; no test exercises the call site
- Gap 4 (unconditional current_iter): cycle-orchestrator.sh lines 2325–2329 read current_iter without `_ZBUILD_RESUME_ACTIVE` guard ✓
- resume-loop-state-test.sh line 76: `cycle_orchestrator_run` called WITHOUT `_ZBUILD_RESUME_ACTIVE=true` set ✓

---

## Summary of known-passing items (no changes needed)

- resume-rehydrate-test.sh: wc -l used ✓, --no-resume on SPEC-12 ✓, cycled block removed ✓, SPEC-13 section (lines 634–645) benign ✓
- from-stage-rehydrate-test.sh: wc -l used ✓
- pipeline-resume-test.sh: intake-result.json pre-written at line 255 ✓
- resume-after-sigint-test.sh: mock_plugin_factory "intake" writes intake-result.json ✓
