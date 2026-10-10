# Design checkpoint — issue #1668 (iteration 3 verification)

## Previous rounds
- Iteration 1: found basic scope (simple.yaml, deployed.yaml, ADR-068, etc.)
- Iteration 2: added impact-max-turns-test.sh, template-always-run-test.sh, 9 shape-floor files; SPEC-8/SPEC-9

## Iteration 3 verification
Files verified this round:
- impact-max-turns-test.sh: line 22 calls `load_template simple.yaml`, asserts router_max_turns/timeout for impact → confirmed need for inline fixture (SPEC-8 correct)
- template-always-run-test.sh line 63: `${#_TPL_STAGES[@]} == 20` → confirmed need to change to 19 (SPEC-9 correct)
- Shape-floor golden files (full-pipeline, parity): NO impact references → no changes needed; already correct
- shape-floor-content-stable-test.sh: uses `impact` as synthetic fixture string in written file, not loading simple.yaml → no change needed
- build-oos-pass-request-test.sh: same synthetic pattern → no change needed
- change-scope-floor-test.sh: same synthetic pattern → no change needed
- core-pipeline-template-test.sh: loads `tests/fixtures/templates/multi-cycle.yaml` (has its own impact entry), NOT simple.yaml → no change needed
- template-resolvability-preflight-test.sh: SPEC-6 loads all config/templates/*.yaml and checks resolvability; after removing impact, remaining stages still resolve → no change needed
- impact-prefilter-order-detector-test.sh: uses `design` as fixture string, no connection to simple.yaml → no change needed
- shape-floor-summary-plain-test.sh: uses `impact` as synthetic fixture string → no change needed

## Conclusion
Design.md is correct and complete. All shape-floor files are in scope but most need no edits. The build needs to:
1. Fix impact-max-turns-test.sh → SPEC-8
2. Fix template-always-run-test.sh count 20→19 → SPEC-9
3. Golden/shape-floor test files need no edits (they're in scope for verification only)
