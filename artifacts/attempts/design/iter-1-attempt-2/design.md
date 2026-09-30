# Design: Migrate impact plugin to contract v2 (#1838)

## Architectural Decision Summary

**Goal.** Migrate `plugins/agent/impact` to the ADR-054 contract v2 shape: one result file on every exit path, `disposition` from `router_reason_disposition`, `rc ∈ {0,1}`, router budgets declared in the manifest, inputs read from the engine's index (`ZBUILD_STAGE_INPUTS`), signal handling via `stage_signal_begin/end`, and no artifact paths constructed inside plugin code.

**Context.** Impact is the only agent plugin remaining at v1 in the F-wave migration (#1833–#1849). Its `impact_run` currently derives paths from `state_file` (the v1 calling convention), writes bare `schema_version:1` envelopes on router failure paths, has no signal guard, returns `rc=2` on early exits, and has no `config.router` defaults in its manifest. The three integration tests that call `impact_run "impact" "$STATE_FILE"` directly will need their setup updated to provide `ZBUILD_STAGE_INPUTS` and `ZBUILD_ARTIFACT_DIR`.

**Decision.** Follow the plan's 10-step sequence (test-first, then implementation). Split `impact_run` into a signal-guarded wrapper and a `_plan_run_entry`-style entry function. Add `_impact_write_result` and `_impact_input` helpers modelled on their plan counterparts. Add `result_contract: 2` and a `config.router` block (timeout\_s: 600, max\_turns: 45; no retries — the template wins and the plan explicitly says impact no longer carries its own `router.retries`) to the manifest. Update the three integration tests whose `impact_run` call site assumes the old state_file derivation, and update the router-timeout test whose assertion on `.router_rc` breaks when the router failure paths switch to the v2 result shape (which carries `disposition` + `reason` but not `router_rc`). The manifest `config.router` values are defaults that sit below the template accessor in the `_route_resolve_knob` chain (`template > env > manifest > constant`); simple.yaml's per-stage `timeout_s: 600`, `max_turns: 45`, and `retries: 1` continue to win.

```scope
plugins/agent/impact/manifest.yaml
plugins/agent/impact/plugin.sh
tests/unit/impact-v2-result-contract-test.sh
tests/unit/impact-v2-disposition-test.sh
tests/unit/impact-no-path-construction-test.sh
tests/golden/impact-passing-run.json
tests/integration/impact-prefilter-781-regression-test.sh
tests/integration/impact-envelope-recovery-test.sh
tests/integration/impact-scope-plateau-test.sh
tests/integration/impact-router-timeout-782-test.sh
tests/integration/impact-pipeline-test.sh
tests/integration/design-impact-cycle-integration-test.sh
tests/unit/impact-max-turns-test.sh
tests/unit/impact-tier-test.sh
tests/unit/impact-persona-framing-test.sh
tests/unit/impact-prompt-override-test.sh
tests/unit/impact-hallucination-filter-test.sh
tests/unit/impact-scope-plateau-test.sh
tests/unit/impact-envelope-recovery-test.sh
tests/unit/impact-prefilter-test.sh
tests/unit/impact-prefilter-order-detector-test.sh
tests/unit/router-manifest-budget-test.sh
tests/lib/run-status-comment-mock-roster.sh
docs/adr/ADR-054-stage-contract.md
docs/wiki/plugins/impact.md
scripts/lib/router-rc-classify.sh
scripts/lib/stage-signal.sh
scripts/lib/plugin-bootstrap.sh
core/pipeline/disposition.sh
core/contract/version.sh
config/templates/simple.yaml
```

```acceptance
SPEC-1[change]: impact_run writes a result_contract:2 JSON with verdict, disposition, and reason on every early-exit path (missing ZBUILD_ARTIFACT_DIR → broken/broken, missing required input → broken/broken)
SPEC-2[change]: impact_run installs a stage_signal_begin guard; an interruption before any result is written produces result_contract:2 with disposition=interrupted, reason=signal_interrupt
SPEC-3[change]: _impact_run_inner writes result_contract:2 on router failure paths with disposition from router_reason_disposition and reason from the router rc classifier (no router_rc field in the v2 result)
SPEC-4[change]: _impact_run_inner writes result_contract:2 on the success path with disposition=complete and reason populated from the verdict summary
SPEC-5[change]: manifest.yaml declares result_contract: 2 under provides
SPEC-6[change]: manifest.yaml declares a config.router block with timeout_s: 600 and max_turns: 45
SPEC-7[change]: impact_run reads scope_manifest, design, and plan input paths from ZBUILD_STAGE_INPUTS (the engine's index) rather than constructing them from the state_file argument
SPEC-8[change]: plugins/agent/impact/plugin.sh contains no hardcoded artifact path constructions (no string literals of the form artifacts_dir/design.md, state_dir/scope-manifest.md, etc. built by the plugin)
SPEC-9[change]: impact_run (v2 calling convention: ZBUILD_STAGE_INPUTS + ZBUILD_ARTIFACT_DIR) writes impact.json and returns rc=0 on a router timeout (rc=124)
SPEC-10[guard]: _impact_run_inner writes verdict=incomplete on a recoverable router failure (rc=124 or rc=1) so the cycle re-iterates
SPEC-11[guard]: _impact_run_inner writes verdict=error on a genuine infra failure (rc=137 OOM kill) so the cycle blocked-predicate can flag it
SPEC-12[change]: impact.json on the success path carries both v2 envelope fields (result_contract=2, disposition=complete) and the original LLM data (schema_version, verdict, missing[]) — the v2 merge preserves all LLM-authored fields
SPEC-13[guard]: when impact's manifest declares config.router.timeout_s: 600 and a per-stage template accessor returns a different value, _route_resolve_timeout returns the template value — the manifest acts as a default, not an override (template > manifest precedence preserved per _route_resolve_knob)
WIRING: plugins/agent/impact/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/impact-v2-result-contract-test.sh
SPEC-2: tests/unit/impact-v2-result-contract-test.sh
SPEC-3: tests/unit/impact-v2-result-contract-test.sh tests/integration/impact-router-timeout-782-test.sh
SPEC-4: tests/unit/impact-v2-result-contract-test.sh
SPEC-5: tests/unit/impact-v2-result-contract-test.sh
SPEC-6: tests/unit/impact-v2-result-contract-test.sh
SPEC-7: tests/unit/impact-v2-result-contract-test.sh
SPEC-8: tests/unit/impact-no-path-construction-test.sh
SPEC-9: tests/integration/impact-router-timeout-782-test.sh
SPEC-10: tests/integration/impact-router-timeout-782-test.sh
SPEC-11: tests/integration/impact-router-timeout-782-test.sh
SPEC-12: tests/integration/impact-pipeline-test.sh
SPEC-13: tests/unit/impact-v2-result-contract-test.sh
```

LOOP_COMPLETE
