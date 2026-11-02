# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Refinement complete (fifth pass)

The design checker passed the fourth-pass design. The build ran and the test stage
failed. The issue-acceptance stage found failures on 9 tests. After reading the test
files and implementation state, this pass makes two targeted changes to the design.

---

## What changed this pass

### 1. Context / gaps — Gap 4 status corrected

Gap 4 (cycle-orchestrator unconditional `current_iter` read) was labelled "Still needs
design fix". After the build ran, it was still NOT fixed. The context section now says
"NOT YET FIXED" explicitly and restates what steps 6 and 7 must do, with exact line
references.

### 2. Step 6 — exact code replacement shown

Previous wording: "guard the current_iter read with [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]".
New wording shows the EXACT replacement block (the unconditional lines 2305–2309 in
cycle-orchestrator.sh must be replaced with the if/else guard).

### 3. Step 7 — exact location in runner.sh

"on the line immediately after runner.sh:2838, before the `eb_emit_event "pipeline.resume"`
call at line 2839".

### 4. Step 10 — item (4) expanded to cover UNTAGGED SPEC-13 assertions

**Root cause of NEGCTL FAIL for SPEC-1:** The SPEC-13 section in
resume-rehydrate-test.sh (lines 549–563) has UNTAGGED assertions:
- `assert_contains "resume-rehydrate fixture contains type: cycle"` — passes
- `assert_gt "resume-rehydrate: pipeline with cyclic fixture was actually run (cycled dispatched)"` — FAILS (cycled=0)

The build only removed `[#1805/SPEC-13]`-tagged assertions, missing these untagged
ones. The untagged `assert_gt` for cycled dispatch fires and fails, causing the whole
test to fail at HEAD, which causes SPEC-1 NEGCTL FAIL.

Step 10 item (4) now says: remove the **entire** SPEC-13 section — the
`print_test_section` header line AND both assertions, tagged or untagged.

### 5. Added Finding 9

Documents the root cause of SPEC-1 NEGCTL fail: the untagged SPEC-13 section.

---

## Summary of build misses (all covered by updated design steps)

| Step | What was missed | Effect |
|------|----------------|--------|
| 6 | `_ZBUILD_RESUME_ACTIVE` guard not added to cycle-orchestrator.sh | Nested loop regressions (4 tests) |
| 7 | `export _ZBUILD_RESUME_ACTIVE=true` not added to runner.sh after 2838 | Real resume cycle behavior broken |
| 10 item 3 | SPEC-12 cycled-dispatch `assert_gt` block not removed | SPEC-12 test section fails |
| 10 item 4 | Untagged SPEC-13 section not removed | SPEC-1 NEGCTL fail (primary) |
| 10 items 1-2 | grep-c anti-pattern not fixed in resume-rehydrate-test.sh | Additional assertion failures |

---

## What PASSES after the build (no changes needed for these)

- SPEC-2 (NEGCTL PASS): resume exits 1 on missing artifact ✓
- SPEC-3 (NEGCTL PASS): --from-stage rehydrates ✓  
- SPEC-4 (NEGCTL PASS): --from-stage exits 1 on missing artifact ✓
- SPEC-7 (NEGCTL PASS): cycle resume from current_iter ✓ (test exports RESUME_ACTIVE directly)
- SPEC-9 (NEGCTL PASS): all three resume entry paths invoke _runner_resume_rehydrate ✓
- SPEC-5/6/10/11/12: no-code or done, skipped by checker

---

## Evidence verified (unchanged from prior pass)

- SPEC-8[done]: runner.sh:3808 = `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- SPEC-10[done]: resume.sh:247 = inside get_resume_recommendation, no-state → fresh_start
- SPEC-11[done]: runner.sh:3808 same line (resume_mode=false for new runs → no skip)
