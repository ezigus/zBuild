# Plan stage checkpoint — issue #1668

## Files read and what they told me

- `config/templates/simple.yaml`: impact is in delivery_loop.flow (line 86), has a 29-line stage block (lines 345-373) with banner comment, and is referenced in delivery_loop banner comment (lines 85-86) and design_verify_cycle banner (lines 119-123: "SEMANTIC sibling…placed AFTER this cycle").
- `config/templates/deployed.yaml`: impact in delivery_loop.flow (line 62), stage block lines 170-181 (12 lines + banner comment line 170).
- `tests/unit/template-simple-yaml-test.sh`: SPEC-2 asserts count=20 and _expected_stages includes impact at index 6; SPEC-3 has 4 impact assertions (roles/io/timeout/max_turns at lines 138-141); SPEC-13 asserts `_TPL_STAGES[6] == impact`; SPEC-18 asserts delivery_loop stages as `design_verify_cycle,impact,build_test_cycle`.
- `tests/integration/core-pipeline-cycle-build-test-wiring-test.sh`: T1 asserts delivery_loop as `design_verify_cycle,impact,build_test_cycle` (line 61).
- `tests/lib/run-status-comment-mock-roster.sh`: defines `_make_impact_plugin()` (dead, never called) lines 57-91, and calls `_make_plugin "impact" "impact_analyzer"` at line 335.
- 4 integration tests (cycle-gate-unavailable-aborts-run-test.sh, cycle-rate-limit-aborts-run-test.sh, cycle-acceptance-terminal-failure-test.sh): each has an inline `_make_impact_plugin()` function AND a `_make_plugin "impact" "impact_analyzer"` call.
- `cycle-on-max-pipeline-continues-test.sh`: has comments referencing impact (lines 52, 61) and `_make_plugin "impact" "impact_analyzer"` call at line 231.
- `docs/adr/ADR-068-nested-loops-and-finding-answers.md`: §1 says "design loop → impact → build loop"; §8 says "the design loop's stages, impact, …"; Enforced by §1 points to no-fault-routing-test.sh R1 (route_back refusal — doesn't enforce the flow roster). Need to add template-simple-yaml-test.sh SPEC-18.
- `tests/integration/deployed-template-e2e-test.sh` and `tests/unit/template-blocking-reset-test.sh`: NO impact references — confirmed not affected.

## Conclusions

- 8 files need changes (2 templates, ADR, 2 unit/integration tests, mock roster, 4 inline-stub tests — some batched)
- Step ordering: test-first (template-simple-yaml-test.sh changes first to produce red assertion), then templates, then wiring test, then stub cleanup, then ADR
- The "impact absent" RED assertion is in SPEC-18 (delivery_loop stages string drops impact) and a new direct absence check
- `_make_impact_plugin()` in mock-roster and 4 integration tests is dead code (never called); the live stub is `_make_plugin "impact" "impact_analyzer"`
- No changes to plugins/agent/impact/ or its tests

## What would come next if stopped

Emit plan JSON.
