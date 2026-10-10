# Impact Stage Checkpoint

## Issue
#1668 — remove "impact" from delivery_loop.flow in simple.yaml and deployed.yaml

## Status: COMPLETE — verdict ready

## Key change
- `_TPL_STAGES` count: 20 → 19 (impact removed)
- `_TPL_STAGES[6]` was impact, now test-author; shape-floor moves from index 11→10, gate-aggregator 16→15
- `_TPL_CYCLE_STAGES_delivery_loop`: "design_verify_cycle,impact,build_test_cycle" → "design_verify_cycle,build_test_cycle"

## Files verified
- design.md: design removes impact from simple.yaml, deployed.yaml, cleans stubs in 4 integration tests + mock roster, amends ADR-068
- nested-loop-rounds-test.sh: uses own inline fixture template with impact — NOT affected by simple.yaml change
- shape-floor-content-stable-test.sh: creates fixture with `_TPL_STAGES[2]="impact"` string as evidence token — not loading real template
- shape-floor-summary-plain-test.sh: same pattern — fixture only
- build-oos-pass-request-test.sh: same pattern — fixture only
- change-scope-floor-test.sh: same pattern — fixture only
- impact-prefilter-order-detector-test.sh: creates fake simple.yaml in temp dir — not real template
- parity run-fixture.sh: uses `extends: simple` with FULL flow replacement; flow does NOT include impact
- core-pipeline-template-test.sh: 8-stage custom fixture, NOT simple.yaml
- core-pipeline-template-cycles-test.sh: own fixture with impact at index 3 (8-stage custom template)
- gate-aggregator-roster-test.sh: own _TPL_CYCLE_STAGES_mycycle, not simple.yaml
- simple-yaml-build-test-convergence-test.sh: asserts build_test_cycle stages (not delivery_loop), not affected
- preflight-contract-templates-test.sh: uses _TPL_STAGES[] but doesn't pin count or impact

## CONFIRMED SCOPE GAP
**tests/unit/template-always-run-test.sh** (NOT in design scope):
- Line 38: `load_template "$REPO_ROOT/config/templates/simple.yaml"`
- Line 62-63: `assert_eq "[SPEC-2] simple.yaml flow count excludes both always-run stages" "20" "${#_TPL_STAGES[@]}"`
- After removing impact, count becomes 19. This assertion FAILS.

## Golden files
- tests/golden/full-pipeline/event-sequence.golden: only generic event types, no stage-name/count pinning for delivery_loop
- tests/golden/parity/event-sequence.golden: 8 stage pairs — but parity fixture uses own flow without impact, so NOT affected

## Verdict: incomplete (template-always-run-test.sh missing from scope)
