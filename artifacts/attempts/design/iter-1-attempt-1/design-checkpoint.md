# Design checkpoint — issue #1668 (COMPLETE)

## Files read
- plan.json, requirements.json: confirmed scope and 5-step plan
- config/templates/simple.yaml: impact at lines 345-373; delivery_loop flow: design_verify_cycle, impact, build_test_cycle
- config/templates/deployed.yaml: impact at lines 170-181; delivery_loop mirrors simple
- tests/unit/template-simple-yaml-test.sh: SPEC-2 (count=20), SPEC-3 (4 impact assertions), SPEC-12 (shape-floor[11], gate-agg[16]), SPEC-13 (_TPL_STAGES[6]==impact), SPEC-18 (delivery_loop="design_verify_cycle,impact,build_test_cycle")
- tests/integration/core-pipeline-cycle-build-test-wiring-test.sh: T1 asserts "design_verify_cycle,impact,build_test_cycle"
- docs/adr/ADR-068-nested-loops-and-finding-answers.md: §1 says "design loop → impact → build loop"; §8 mentions impact in halt check; Enforced by §1 points to no-fault-routing-test.sh R1
- tests/lib/run-status-comment-mock-roster.sh: _make_impact_plugin() function (lines 57-91) + _make_plugin "impact" (line 335)
- All 4 integration tests: each has _make_impact_plugin() + _make_plugin "impact" as dead/live stubs

## Conclusions
New stage indices after removing impact from simple.yaml (19 total):
  0:hydrate 1:intake 2:plan 3:design 4:spec-coverage 5:design-gate 6:test-author 7:spec-correspondence 8:build 9:test 10:shape-floor 11:acceptance-gate 12:secret-scan 13:assertion-integrity 14:issue-acceptance 15:gate-aggregator 16:review_lenses 17:review-aggregator 18:pr

WIRING: config/templates/simple.yaml and config/templates/deployed.yaml (if reverted, SPEC-18 fails)

Also found: docs/wiki/Configuration.md and docs/wiki/Pipeline-and-Stages.md reference impact in the delivery flow — out of plan scope but in scope block.

## Design document: WRITING NOW
