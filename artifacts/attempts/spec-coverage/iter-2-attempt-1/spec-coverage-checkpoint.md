# Spec-coverage checkpoint (final)

## Files read
- design.md: 7 SPECs covering R-1–R-5; TESTFILES: SPEC-1/SPEC-2→template-simple-yaml-test.sh, SPEC-3→core-pipeline-cycle-build-test-wiring-test.sh, SPEC-7→deployed-template-e2e-test.sh
- requirements.json: 5 requirements R-1–R-5
- core-pipeline-cycle-build-test-wiring-test.sh: T1 loads simple.yaml, covers simple.yaml delivery_loop roster
- deployed-template-e2e-test.sh: currently no delivery_loop assertion; SPEC-7 adds one

## Key correction from resumed analysis
Prior checkpoint counted 6 SPECs, missed SPEC-7. SPEC-7[code] covers deployed.yaml:
- Adds assertion to deployed-template-e2e-test.sh: _TPL_CYCLE_STAGES_delivery_loop equals "design_verify_cycle,build_test_cycle"
- Fails on main (reddens) — satisfies R-1 for deployed.yaml
- Covers: R-1 R-5

## Coverage summary
- R-1: SPEC-1 (simple.yaml assertion, reddens on main) + SPEC-7 (deployed.yaml assertion, reddens on main) — COVERED
- R-2: SPEC-6[done] — plugin/tests untouched — COVERED
- R-3: SPEC-2 (count/indices) + SPEC-3 (wiring test roster) — COVERED
- R-4: SPEC-5[no-code] — ADR-068 §1/§8 amended, Enforced-by updated — COVERED
- R-5: Runtime dogfood — deferred per instructions

## Verdict: COVERED
