# Spec-coverage checkpoint

## Files read
- design.md: 6 SPECs covering R-1–R-5; TESTFILES lists template-simple-yaml-test.sh for SPEC-1/SPEC-2 and core-pipeline-cycle-build-test-wiring-test.sh for SPEC-3
- requirements.json: 5 requirements R-1–R-5
- core-pipeline-cycle-build-test-wiring-test.sh: T1 loads simple.yaml (line 43), NOT deployed.yaml; no mention of deployed.yaml anywhere in the file
- deployed-template-e2e-test.sh: checks _TPL_STAGES for deploy/validate/monitor, no delivery_loop cycle-roster assertion
- template-blocking-reset-test.sh: references _TPL_STAGES incidentally, no delivery_loop or impact assertions

## Conclusions
R-1 UNCOVERED (partially): R-1 requires "a test asserting impact is absent from delivery_loop in **both** shipped templates". SPEC-1 claims to cover both simple.yaml and deployed.yaml, but its TESTFILES only names tests/unit/template-simple-yaml-test.sh. SPEC-3 (core-pipeline-cycle-build-test-wiring-test.sh) also only covers simple.yaml (T1 loads simple.yaml, confirmed). No SPEC names a test that enforces impact's absence from deployed.yaml's delivery_loop.

R-2: Covered by SPEC-6[done] and SPEC-4.
R-3: Covered by SPEC-2 (simple.yaml count/indices) and SPEC-3 (wiring test).
R-4: Covered by SPEC-5 (ADR-068 §1/§8 amendment, lint-adr-enforced-by.sh pointer).
R-5: Runtime dogfood verification — can only be judged once the change exists; not in UNCOVERED per instructions.

## Verdict
UNCOVERED — R-1 gap: deployed.yaml's delivery_loop has no SPEC test enforcing impact's absence.
