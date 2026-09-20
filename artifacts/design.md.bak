# Design: Verify review-lens v2 migration (Issue #1840)

## Architectural Decision Summary

**Goal.** Confirm the review-lens plugin's migration to contract v2 (ADR-055) is complete, and that all SPEC-1–SPEC-21 assertions in the acceptance test pass. Fix any remaining gaps discovered during verification.

**Context.** The `review-lens` plugin (`kind: agent`, `convergence: advisory`) was migrated on the current branch from contract v1 to v2. Contract v2 requires: `result_contract:2` in every terminal output; the `verdict`/`disposition`/`reason` fields embedded in the primary output JSON; dedicated exit codes for rc=10 (budget exhausted) and rc=130 (SIGINT interrupted), each distinct from the advisory rc=0 degrade paths; ADR-063 budget-guidance blocks in the prompt (both TURN BUDGET and WALL CLOCK BUDGET); ADR-028 schema-gated envelope parsing; and ADR-055 name-matched `inputs` (id+required only). The test file (`review-lens-test.sh`) contains SPEC-1–SPEC-19 assertions in a dedicated `#1840: v2 contract migration — acceptance assertions` section.

The manifest has been verified to declare:
- `provides.result_contract: 2` ✓
- `provides.role: review_lens` ✓
- `provides.events` with exactly three entries (review_lens.failed, review_lens.redaction_failed, review_lens.unparseable) ✓
- `config.valid_verdicts: [complete, degraded]` ✓
- `config.router.timeout_s: 300` and `config.router.max_turns: 10` ✓
- `inputs` entries with only `id` and `required` fields ✓
- `outputs[].lens_result` with `primary: true` ✓
- `outputs[].review_lens_summary` with `summary: true` ✓ (ADR-055 §9; SPEC-16 guards preservation)
- `hooks.cleanup` absent with ADR-054 §7 comment ✓

The plugin source has been verified to implement:
- `_review_lens_write_result` function (no hardcoded path literals) ✓
- `_review_lens_interrupt_handler` for SIGTERM simulation ✓
- rc=130 path → disposition:interrupted ✓
- rc=10 path → disposition:exhausted, reason:budget_exhausted ✓
- `_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok` ✓
- ADR-063 TURN BUDGET and WALL CLOCK BUDGET guidance block injection ✓
- No merge-action coercion tokens (approve/request_changes/"block") ✓

**SPEC classification.** Four SPECs are `[guard]` because the behavior existed in v1 and must be preserved through the migration (SPEC-8, SPEC-12, SPEC-16, SPEC-17). SPEC-20 is `[guard]` because `provides.role` binding predates this migration (the resolver used it in v1). The remaining sixteen are `[change]` because they test behaviors first introduced by the v2 migration.

- **SPEC-9 [change]**: the test calls v2 `_review_lens_run_inner`; at v1 merge-base the function does not write v2 fields (result_contract, verdict, disposition, reason), so the assert on those fields fails.
- **SPEC-10 [change]**: Part 2 checks that `_review_lens_write_result` (a v2 addition) contains `verdict` as a jq field; at v1 baseline the function doesn't exist — assertion fails with "absent".
- **SPEC-19 [change]**: if v1 manifest had `hooks.cleanup`, the assertion fails at baseline.
- **SPEC-20 [guard]**: `provides.role: review_lens` binding was present in v1 (resolver.sh reads this field); the guard ensures the v2 migration does not accidentally remove it.
- **SPEC-21 [change]**: `provides.events` inline declaration in the manifest per ADR-001 §"Declared events" (#1717) is a new v2 adoption; at v1 merge-base this block was absent.

**Decision.** Scope verification to the four seed files plus every test that references review_lens role, result_contract shape, or v2 output fields; the ADRs whose contracts the migration implements; and the engine files that consume `result_contract` and `disposition`. SPEC-20 and SPEC-21 are added to close the spec-coverage gap flagged by the spec-coverage stage (provides.role #1704 and provides.events #1717 were required by the issue but had no SPEC validating them).

---

```scope
plugins/agent/review-lens/plugin.sh
plugins/agent/review-lens/manifest.yaml
plugins/agent/review-lens/lib/charters.sh
plugins/agent/review-lens/tests/review-lens-test.sh
docs/wiki/plugins/review-lens.md
docs/adr/ADR-028-shared-llm-agent-framework.md
docs/adr/ADR-040-composable-gate-lens-taxonomy.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/adr/ADR-001-plugin-contract.md
docs/adr/ADR-004-redaction-chokepoint.md
docs/adr/ADR-036-acceptance-contract-teeth.md
docs/adr/ADR-061-fault-class-vocabulary.md
config/event-schema.json
core/contract/version.sh
core/pipeline/disposition.sh
core/pipeline/verdict.sh
core/pipeline/dispatch.sh
core/pipeline/contract-validator.sh
core/pipeline/input-resolve.sh
core/pipeline/runner.sh
core/pipeline/resolver.sh
core/plugin-registry/lifecycle.sh
core/plugin-registry/manifest-validation.sh
scripts/lib/llm-agent.sh
scripts/lib/lint-llm-envelope.sh
scripts/lib/stage-summary.sh
tests/unit/adr-migration-claims-test.sh
tests/unit/spec-correspondence-test.sh
tests/unit/lifecycle-required-output-test.sh
tests/unit/artifact-render-lens-test.sh
tests/unit/stage-resolution-parity-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/review-lens-report-merge-base-bundle-test.sh
tests/integration/review-lenses-output-test.sh
tests/integration/adr040-isolated-gate-test.sh
tests/integration/review-report-advisory-flow-test.sh
tests/integration/map-review-lenses-dispatch-test.sh
tests/integration/dispatch-rc-signal-boundary-test.sh
plugins/agent/review-aggregator/plugin.sh
plugins/agent/review-aggregator/manifest.yaml
```

```acceptance
SPEC-1[change]: success path writes result_contract:2, verdict:complete, disposition:complete, and non-empty reason in lens-<name>.json
SPEC-2[change]: router-failure degrade path writes result_contract:2, verdict:degraded, disposition:broken in lens file
SPEC-3[change]: unparseable-reply degrade path writes result_contract:2, verdict:degraded, disposition:broken in lens file
SPEC-4[change]: schema-gate recovery (_llm_envelope_parse --schema-gate _review_lens_envelope_schema_ok) finds valid first-object over a postamble-bearing response
SPEC-5[change]: ADR-063 TURN BUDGET block is injected in the prompt when _route_resolve_max_turns > 0
SPEC-6[change]: manifest declares config.router.timeout_s and config.router.max_turns; _route_resolve_timeout/_route_resolve_max_turns return manifest values when no template or env override is set
SPEC-7[change]: manifest provides.result_contract == 2 and config.valid_verdicts declares both complete and degraded; validate_manifest passes
SPEC-8[guard]: existing advisory degrade behavior (rc=0, review_lens.failed/unparseable events, advisory-absence stage summary) is unchanged
SPEC-9[change]: passing run output is backward-compatible — pre-existing v1 fields (schema_version, name, score, findings[]) are present and unmodified in a successful lens result; the v2 additions (result_contract, verdict, disposition, reason) are purely additive with no field removed
SPEC-10[change]: merge-action coercion tokens (approve, request_changes, "block") are absent from plugin.sh and charters.sh; verdict appears in _review_lens_write_result body only as a jq field, and the amended coercion grep does not false-positive on it
SPEC-11[change]: _review_lens_write_result function exists in plugin.sh and its body contains no hardcoded artifact path literals
SPEC-12[guard]: manifest outputs[].lens_result declares primary: true
SPEC-13[change]: rc=130 path propagates rc=130 and writes disposition:interrupted; _review_lens_interrupt_handler directly callable for SIGTERM simulation
SPEC-14[change]: template accessor wins over manifest value in ADR-063 budget block (sentinel 99 overrides manifest default)
SPEC-15[change]: rc=10 path propagates rc=10 and writes disposition:exhausted, reason:budget_exhausted (distinct from advisory rc=0 and rc=130)
SPEC-16[guard]: manifest outputs section declares review_lens_summary output with summary: true (ADR-055 §9 — presence preserved through v2 migration)
SPEC-17[guard]: success path writes lens-<name>-summary.md containing affirmative pass-verdict language (reviewed/-- pass); behavior preserved through v2 migration
SPEC-18[change]: WALL CLOCK BUDGET block is injected in the prompt when _route_resolve_timeout returns a positive value (ADR-063 §1 — new in v2; v1 plugin had no _review_lens_wallclock_guidance call)
SPEC-19[change]: hooks.cleanup is absent from manifest.yaml; manifest carries an ADR-054 §7 explanatory comment
SPEC-20[guard]: manifest provides.role == review_lens (ADR-040 role-binding contract, #1704 — present in v1, must survive v2 migration)
SPEC-21[change]: manifest provides.events declares exactly three events (review_lens.failed, review_lens.redaction_failed, review_lens.unparseable) per ADR-001 §"Declared events" (#1717 — new inline declaration in v2; absent at v1 merge-base)
WIRING: plugins/agent/review-lens/manifest.yaml
TESTFILES:
SPEC-1: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-2: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-3: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-4: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-5: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-6: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-7: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-8: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-9: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-10: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-11: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-12: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-13: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-14: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-15: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-16: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-17: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-18: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-19: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-20: plugins/agent/review-lens/tests/review-lens-test.sh
SPEC-21: plugins/agent/review-lens/tests/review-lens-test.sh
```
