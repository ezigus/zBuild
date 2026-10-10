# Design: Remove `impact` from shipped templates (issue #1668)

## Decision summary

**Goal:** Remove `impact` from the `delivery_loop.flow` of both shipped templates (`simple.yaml` and `deployed.yaml`), leaving `plugins/agent/impact/` and its unit tests untouched, and amend ADR-068 §1/§8 to match.

**Context:** `delivery_loop` currently sequences `design_verify_cycle → impact → build_test_cycle`. The impact stage is an LLM-heavy advisory stage (T2, 600 s, 45 turns) that runs once per outer loop. Removing it from the shipped templates shortens the pipeline while preserving the plugin for standard.yaml's `design_impact_cycle` and for future reuse. Tests pinning the delivery_loop roster, stage count, and stage indices all become stale and must be updated.

**Decision:** Delete the `- impact` entry from `delivery_loop.flow` and the `impact:` stage section from both templates. Update every test that pins the roster, count, or positional index of any stage whose value shifts as a result (shape-floor, gate-aggregator, and impact itself). Remove the dead `_make_impact_plugin()` stubs and the live `_make_plugin "impact"` calls from the integration test mock rosters, because the runner's resolvability preflight will no longer require an impact plugin. Amend ADR-068 §1 and §8 to describe the two-member `delivery_loop` flow and update the Enforced by pointer for §1.

```scope
config/templates/simple.yaml
config/templates/deployed.yaml
docs/adr/ADR-068-nested-loops-and-finding-answers.md
tests/unit/template-simple-yaml-test.sh
tests/integration/core-pipeline-cycle-build-test-wiring-test.sh
tests/integration/cycle-acceptance-terminal-failure-test.sh
tests/integration/cycle-gate-unavailable-aborts-run-test.sh
tests/integration/cycle-on-max-pipeline-continues-test.sh
tests/integration/cycle-rate-limit-aborts-run-test.sh
tests/lib/run-status-comment-mock-roster.sh
docs/adr/ADR-046-design-verify-shift-left.md
docs/wiki/Configuration.md
docs/wiki/Pipeline-and-Stages.md
```

```acceptance
SPEC-1[code]: `delivery_loop.flow` in both simple.yaml and deployed.yaml contains exactly `[design_verify_cycle, build_test_cycle]` — impact is absent from both; SPEC-18 in template-simple-yaml-test.sh (updated to assert `"design_verify_cycle,build_test_cycle"`) fails on main because the template has `"design_verify_cycle,impact,build_test_cycle"` covers: R-1 R-5
SPEC-2[code]: `_TPL_STAGES` for simple.yaml has exactly 19 entries (not 20); `impact` does not appear in the list; shape-floor is at index 10 (was 11) and gate-aggregator at index 15 (was 16); SPEC-2 count assertion and the SPEC-12/SPEC-13 index assertions fail on main covers: R-3
SPEC-3[code]: T1 in core-pipeline-cycle-build-test-wiring-test.sh asserts `_TPL_CYCLE_STAGES_delivery_loop` equals `"design_verify_cycle,build_test_cycle"` (no impact); the assertion fails on main where the template has `"design_verify_cycle,impact,build_test_cycle"` covers: R-1 R-3
SPEC-4[no-code]: `_make_impact_plugin()` function bodies and `_make_plugin "impact" "impact_analyzer"` calls removed from the four integration test files and the mock roster; these are dead stubs once the resolvability preflight no longer requires impact covers: R-2 R-5
SPEC-5[no-code]: ADR-068 §1 amended to read "design loop → build loop" (impact removed from the flow description); §8 amended to remove impact from the stages enumerated in the halt check; Enforced by §1 updated to add tests/unit/template-simple-yaml-test.sh SPEC-18 as the roster enforcer (R1 for route_back refusal is retained); an "Amended 2026-10-10" note added to the document header covers: R-4
SPEC-6[done]: plugins/agent/impact/ directory and all its unit and integration tests are untouched; impact plugin tests drive the plugin via inline fixture templates or directly, never via simple.yaml or deployed.yaml covers: R-2 evidence: plugins/agent/impact/manifest.yaml tests/unit/impact-v2-result-contract-test.sh tests/integration/impact-pipeline-test.sh
WIRING:
config/templates/simple.yaml
config/templates/deployed.yaml
TESTFILES:
SPEC-1: tests/unit/template-simple-yaml-test.sh
SPEC-2: tests/unit/template-simple-yaml-test.sh
SPEC-3: tests/integration/core-pipeline-cycle-build-test-wiring-test.sh
```

```supersedes
tests/unit/template-simple-yaml-test.sh [SPEC-18]: asserts `_TPL_CYCLE_STAGES_delivery_loop` equals `"design_verify_cycle,impact,build_test_cycle"` — after the change the correct value is `"design_verify_cycle,build_test_cycle"`
tests/unit/template-simple-yaml-test.sh [SPEC-2]: asserts `_TPL_STAGES` count is 20 and lists `impact` in `_expected_stages` — count becomes 19 and impact is removed
tests/unit/template-simple-yaml-test.sh [SPEC-3]: four assertions pin `_TPL_STAGE_ROLES_impact`, `_TPL_STAGE_IO_DESTS_impact`, `_TPL_STAGE_ROUTER_TIMEOUT_impact`, `_TPL_STAGE_ROUTER_MAX_TURNS_impact` — all four vars are unset once the impact section is removed from the template
tests/unit/template-simple-yaml-test.sh [SPEC-12]: asserts `_TPL_STAGES[11] == shape-floor` and `_TPL_STAGES[16] == gate-aggregator` — both indices shift left by one (shape-floor moves to 10, gate-aggregator to 15) when impact is removed
tests/unit/template-simple-yaml-test.sh [SPEC-13]: asserts `_TPL_STAGES[6] == impact` — index 6 is test-author after the change; the impact assertion is deleted
tests/integration/core-pipeline-cycle-build-test-wiring-test.sh [T1]: asserts `_TPL_CYCLE_STAGES_delivery_loop` equals `"design_verify_cycle,impact,build_test_cycle"` — becomes `"design_verify_cycle,build_test_cycle"` after the change
```

LOOP_COMPLETE
