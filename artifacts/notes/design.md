# Design notes: #1805 — resume and --from-stage trust-and-rehydrate

## Status: Refinement complete (fourth pass)

The design checker rejected the previous draft on three findings, all caused by
phantom requirement R-15 (which does not exist in the engine-numbered R-1–R-14):

1. SPEC-13 covered only R-15 → dropped entirely
2. No requirement asks every test file use a cyclic stage → SPEC-13 gone
3. SPEC-5 carried `covers: R-5 R-15` → R-15 removed; now `covers: R-5` only

Everything else in the design (scope, other SPECs, steps, supersedes) is
unchanged from the last passing attempt (iter-1-attempt-6) plus the implementation
fixes from the subsequent attempts (Findings 3–8 in the design).

---

## Changes this pass made

- **Dropped SPEC-13** from acceptance block and TESTFILES
- **Removed R-15** from SPEC-5 covers
- **Step 10** (resume-rehydrate-test.sh): removed "change SPEC-13 assertion" part;
  kept SPEC-12 changes (--no-resume, intake-dispatched assertion). Also added item (4):
  remove any [#1805/SPEC-13]-tagged assertions entirely.
- **Step 12** (resume-entry-points-test.sh): reworded from "change SPEC-13 assertion
  to intake dispatched" to "remove any [#1805/SPEC-13]-tagged assertions entirely".
- Findings 1 and 2 added to document the R-15 drop rationale.
- All prior findings (3–8) preserved as-is.

---

## What the build must implement (unchanged from prior pass)

### Miss 1 — `_ZBUILD_RESUME_ACTIVE` guard not added to cycle-orchestrator.sh
At `_cycle_orchestrator_run_body`, `_persisted_iter` read is unconditional.
Fix (step 6): wrap with `if [[ ${_ZBUILD_RESUME_ACTIVE:-false} == true ]]`.

### Miss 2 — `export _ZBUILD_RESUME_ACTIVE=true` not added to runner.sh
Fix (step 7): add `export _ZBUILD_RESUME_ACTIVE=true` immediately after the
`_runner_resume_rehydrate` call at runner.sh:2838.

### Miss 3 — grep-c anti-pattern on zero-count assertions (5 sites)
Use `wc -l | tr -d ' '` instead of `grep -c ... || echo 0` at:
- resume-rehydrate-test.sh SPEC-1 path-1/2/3
- from-stage-rehydrate-test.sh SPEC-3
- resume-loop-state-test.sh SPEC-7

### Miss 4 — `export _ZBUILD_RESUME_ACTIVE=true` not in resume-loop-state-test.sh
Add before the direct `cycle_orchestrator_run` call (step 9).

### Miss 5 — SPEC-13 assertions (now: remove entirely)
resume-rehydrate-test.sh and resume-entry-points-test.sh had `assert_gt cycled "0"`
tagged [#1805/SPEC-13]. Now these must be deleted (SPEC-13 is dropped).

### Miss 6 — `--no-resume` not in SPEC-12 runner invocation
Add `--no-resume` to prevent auto-resume (step 10).

---

## Evidence verified

- SPEC-8[done]: runner.sh:3808 = `if $resume_mode && [[ -z "$skip_until_stage" ]]`
- SPEC-10[done]: resume.sh:247 = inside get_resume_recommendation, no-state → fresh_start
- SPEC-11[done]: runner.sh:3808 same line (resume_mode=false for new runs → no skip)
