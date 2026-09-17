# Design: Migrate security-lens to contract v2

## Architectural decision summary

**Goal.** Bring `plugins/agent/security-lens` into full compliance with the ADR-054/056/060 result-contract v2 standard: every exit path emits `{result_contract:2, verdict, disposition, reason}`; the manifest declares router budgets, valid verdicts, and provided events; the cleanup hook is a real function; return codes are strictly `∈ {0, 1}`.

**Context.** The plugin was the first agent plugin POC (Phase 0) and pre-dated the v2 result contract. Its findings artifact lacked top-level `verdict`/`disposition`/`reason` fields; the manifest carried `valid_verdicts: []` and no `result_contract`, `provides.events`, or `config.router` declarations; the cleanup hook was absent; and both error exits returned rc=2, violating the `rc∈{0,1}` gate enforced by ADR-056.

**Decision.** Add `_security_lens_write_result` — a single helper that atomically writes the v2 envelope via `jq -n | atomic_write` — and route every terminal exit path through it. Normalize all error exits to rc=1. Add `security_lens_cleanup() { return 0; }` per ADR-056 §4. Update the manifest with `provides.result_contract: 2`, `valid_verdicts: [pass, error]`, `provides.events: [plugin.result, security_lens.failed]`, and `config.router: {timeout_s: 600, max_turns: 45}`. Cover all paths with SPEC-tagged TDD assertions written before the implementation.

```scope
plugins/agent/security-lens/manifest.yaml
plugins/agent/security-lens/plugin.sh
plugins/agent/security-lens/tests/security-lens-test.sh
plugins/agent/security-lens/prompts/security.md
plugins/agent/security-lens/README.md
docs/wiki/plugins/security-lens.md
docs/wiki/Plugins.md
docs/wiki/Writing-Plugins.md
docs/KEEPERS.md
docs/ARCHITECTURE.md
docs/adr/ADR-001-plugin-contract.md
docs/adr/ADR-004-redaction-chokepoint.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-018-stage-invocation-modes.md
docs/adr/ADR-020-inter-stage-data-contract.md
docs/adr/ADR-028-shared-llm-agent-framework.md
docs/adr/ADR-036-acceptance-contract-teeth.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-056-run-cleanup-only-lifecycle.md
docs/adr/ADR-060-stages-return-structure.md
config/event-schema.json
tests/unit/plugin-manifest-contract-audit-test.sh
tests/unit/agent-stages-artifact-metadata-symmetry-test.sh
tests/unit/adr-migration-claims-test.sh
tests/unit/lint-contract-scope-derivation-test.sh
tests/unit/artifact-render-lens-test.sh
tests/unit/tier-resolve-test.sh
tests/unit/plugin-route-source-guard-test.sh
tests/unit/core-output-stage-colors-test.sh
tests/unit/docs-adr-054-references-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/unit/core-event-bus-test.sh
tests/unit/review-aggregator-test.sh
tests/unit/review-report-plugin-test.sh
tests/unit/runner-post-stage-capability-test.sh
tests/integration/artifact-chain-test.sh
tests/integration/artifact-contract-test.sh
tests/integration/core-pipeline-runner-test.sh
tests/integration/route-fd-isolation-test.sh
tests/integration/router-sync-preserves-error-artifacts-test.sh
tests/integration/stage-io-ordering-invariant-test.sh
tests/integration/template-constructs-test.sh
tests/e2e/crash-resume-test.sh
tests/e2e/injection-guard-test.sh
tests/e2e/redaction-edge-cases-test.sh
tests/e2e/zbuild-cli-verbs-test.sh
tests/fixtures/templates/crash-resume-minimal.yaml
tests/golden/parity/run-fixture.sh
scripts/lib/artifact-render.sh
scripts/lib/llm-agent.sh
scripts/lib/lint-contract.sh
scripts/lib/lint-doc-freshness.sh
scripts/lib/manifest-graph.sh
```

```acceptance
SPEC-1[change]: findings.json carries result_contract:2 at the top level on the normal pass exit path
SPEC-2[change]: normal exit path emits verdict=pass and disposition=complete at the top level of findings.json
SPEC-3[change]: router-fatal exit path (rc≥2) writes result_contract:2 with verdict=error and disposition=broken before returning rc=1
SPEC-4[change]: no-state-file path (security_lens_run called with empty state_file) writes result_contract:2 with verdict=error and returns rc=1 (not rc=2)
SPEC-5[change]: security_lens_cleanup is a declared function (not a comment stub) and returns 0
SPEC-6[change]: manifest provides.result_contract is declared as 2
SPEC-7[change]: manifest config.valid_verdicts lists pass and error
SPEC-8[guard]: plugin.result event is emitted on the normal pass exit path with plugin=security-lens
SPEC-9[change]: LLM findings are accessible under .data.findings in the result artifact for backward-compat consumers
SPEC-10[guard]: postamble-junk recovery via _security_lens_envelope_schema_ok returns rc=0 with the real findings count (not empty)
SPEC-11[change]: manifest config.router declares both timeout_s and max_turns budget defaults
SPEC-12[change]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE env var takes precedence over manifest config.router.max_turns at call time
SPEC-13[change]: manifest findings output declares primary: true
SPEC-14[change]: plugin.sh contains no hardcoded artifact path literals (no bare quoted .json/.md paths without a shell variable)

WIRING:
plugins/agent/security-lens/manifest.yaml

TESTFILES:
SPEC-1: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-2: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-3: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-4: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-5: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-6: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-7: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-8: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-9: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-10: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-11: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-12: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-13: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-14: plugins/agent/security-lens/tests/security-lens-test.sh
```
