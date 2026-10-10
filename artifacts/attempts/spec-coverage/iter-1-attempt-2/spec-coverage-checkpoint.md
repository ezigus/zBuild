# Spec-coverage checkpoint (round 2)

## Files read
- design.md: 9 SPECs (SPEC-1 through SPEC-9) covering R-1–R-5
- requirements.json: 5 requirements R-1–R-5
- checkpoint from prior round confirmed as starting point

## Coverage per requirement

**R-1** (test asserts impact absent from delivery_loop in BOTH templates, reddens on main):
- SPEC-1[code]: simple.yaml assertion in template-simple-yaml-test.sh SPEC-18; "fails on main" stated — COVERED
- SPEC-7[code]: deployed.yaml assertion in deployed-template-e2e-test.sh; "fails on main" stated — COVERED
- "state the red step in the PR body" is a process requirement only verifiable once PR exists — deferred per instructions

**R-2** (plugins/agent/impact/ and its unit tests untouched and still pass):
- SPEC-6[done]: impact directory untouched; impact-pipeline-test.sh and impact-v2-result-contract-test.sh drive plugin directly — COVERED
- SPEC-8[no-code]: impact-max-turns-test.sh fixed to use inline fixture so it no longer depends on simple.yaml — COVERED
- Implementation has not yet applied SPEC-8, causing test failure, but the DESIGN covers R-2

**R-3** (template-simple-yaml-test.sh and core-pipeline-cycle-build-test-wiring-test.sh reflect new roster):
- SPEC-2[code]: _TPL_STAGES count=19, indices shifted — COVERED
- SPEC-3[code]: T1 updated to "design_verify_cycle,build_test_cycle" — COVERED

**R-4** (ADR-068 §1/§8 amended, npm run lint green):
- SPEC-5[no-code]: §1 and §8 amended, Enforced-by updated — COVERED

**R-5** (dogfood run completes with no impact stage):
- Runtime behavior only verifiable once change exists — deferred per instructions

## Verdict: COVERED

## Findings answers
- shape-floor findings 1-9: spec-coverage does not change code or tests; nothing to do
- issue-acceptance findings 1-4: implementation failures, not design gaps; SPEC-8/SPEC-9 address the fixes; nothing to do for spec-coverage
- issue-acceptance finding 5: "state the red step in the PR body" is process-only, deferred per instructions
