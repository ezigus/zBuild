# Plan stage checkpoint — issue #1668 (resumed)

## Files read and what they told me

- `config/templates/simple.yaml`: impact in delivery_loop.flow (line 86), 29-line stage block (lines 345-373) with banner comment, referenced in delivery_loop banner (lines 85-86) and design_verify_cycle banner (lines 119-123: "SEMANTIC sibling…placed AFTER this cycle").
- `config/templates/deployed.yaml`: impact in delivery_loop.flow (line 62), stage block lines 170-181 (12 lines + banner comment).
- `tests/unit/template-simple-yaml-test.sh`: SPEC-2 asserts count=20, _expected_stages includes impact at index 6; SPEC-3 has 4 impact assertions (roles/io/timeout/max_turns); SPEC-13 asserts `_TPL_STAGES[6] == impact`; SPEC-18 asserts delivery_loop stages as `design_verify_cycle,impact,build_test_cycle`.
- `tests/integration/core-pipeline-cycle-build-test-wiring-test.sh`: T1 asserts delivery_loop as `design_verify_cycle,impact,build_test_cycle` (line 61).
- `tests/lib/run-status-comment-mock-roster.sh`: dead `_make_impact_plugin()` (lines 57-91) and live `_make_plugin "impact" "impact_analyzer"` at line 335.
- 4 integration tests (cycle-gate-unavailable, cycle-rate-limit, cycle-acceptance, cycle-on-max): each has inline `_make_impact_plugin()` function AND `_make_plugin "impact" "impact_analyzer"` call; cycle-on-max also has impact comments at lines 52/61.
- `docs/adr/ADR-068-nested-loops-and-finding-answers.md`: §1 says "design loop → impact → build loop"; §8 lists impact; Enforced by §1 points to no-fault-routing-test.sh R1 (needs update to template-simple-yaml-test.sh SPEC-18).
- `tests/integration/deployed-template-e2e-test.sh` and `tests/unit/template-blocking-reset-test.sh`: NO impact references — confirmed not affected.

## Conclusions

- 9 files need changes: 2 templates, 1 ADR, 2 primary tests, 1 mock roster, 4 integration stub tests
- Test-first ordering: step-1 writes RED assertions, step-2 removes from templates (GREEN), step-3 fixes remaining test counts/indices, step-4 cleans stubs, step-5 amends ADR
- The RED assertion: update SPEC-18 in template-simple-yaml-test.sh and T1 in core-pipeline-cycle-build-test-wiring-test.sh to expect delivery_loop without impact
- No changes to plugins/agent/impact/ or its unit tests

## Status: COMPLETE — plan JSON emitted
