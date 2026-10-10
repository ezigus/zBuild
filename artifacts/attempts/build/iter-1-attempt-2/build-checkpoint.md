# Build checkpoint — issue #1668 — ITERATION 3

## Current state

All acceptance tests PASS on this tree. The failing test stage summary was from before
the test-author commits (55481a29, 73bcb7a4) landed on the branch.

## Tests verified passing

- tests/unit/template-simple-yaml-test.sh: 105/105 pass
- tests/integration/core-pipeline-cycle-build-test-wiring-test.sh: passes
- tests/integration/deployed-template-e2e-test.sh: 32/32 pass (SPEC-7 passes)
- tests/unit/impact-max-turns-test.sh: 3/3 pass (uses inline fixture, not simple.yaml)
- tests/unit/template-always-run-test.sh: 18/18 pass (count is now "19")
- tests/unit/core-pipeline-template-test.sh: 74/74 pass (uses own multi-cycle fixture)
- tests/unit/shape-floor-content-stable-test.sh: 7/7 pass
- tests/unit/build-oos-pass-request-test.sh: 15/15 pass
- tests/unit/change-scope-floor-test.sh: 5/5 pass
- tests/unit/template-resolvability-preflight-test.sh: 15/15 pass
- tests/unit/impact-prefilter-order-detector-test.sh: 6/6 pass
- tests/unit/shape-floor-summary-plain-test.sh: 7/7 pass
- tests/golden/full-pipeline/event-sequence.golden: 0 impact references — correct
- tests/golden/parity/event-sequence.golden: 0 impact references — correct

## All required changes are already on the branch

1. simple.yaml: impact removed from delivery_loop.flow and stage section removed
2. deployed.yaml: same
3. run-status-comment-mock-roster.sh: _make_impact_plugin() and _make_plugin "impact" removed
4. Four integration cycle tests: same removals
5. ADR-068: §1/§8 amended, "Amended 2026-10-10" added, Enforced by §1 updated
6. impact-max-turns-test.sh: test-author updated to use inline fixture with impact stage
7. template-always-run-test.sh: test-author updated count from 20 to 19
8. deployed-template-e2e-test.sh: SPEC-7 assertion added by test-author

## Nothing left to do — all findings are not reproduced
