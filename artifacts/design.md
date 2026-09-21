# Design: Migrate security-lens to contract v2

## Architectural Decision Summary

**Goal.** Bring `plugins/agent/security-lens` fully into compliance with ADR-054
(stage contract), ADR-056 (run+cleanup-only lifecycle), and ADR-060 (stages return
structure) by adopting the v2 result shape on every exit path.

**Context.** The plugin was the first agent-plugin POC and predates the v2 contract.
It wrote a bare `{findings:[...]}` object with no `result_contract`, no `verdict`, no
`disposition`, and no `reason` field. The `cleanup` hook function existed in plugin.sh
but was never declared in the manifest; `valid_verdicts` and `config.router` were
absent from the manifest; the no-state-file guard returned rc=1 without writing any
result artifact; and the router-fatal branch exited without emitting a v2 envelope.
Each gap is a contract violation that ADR-054 §4–6 now enforces.

**Decision.** Extend `plugin.sh` with a `_security_lens_write_result` helper that
atomically writes `{result_contract:2, verdict, disposition, reason, plugin_id,
generated_at, findings, stub, data:{...}}` and call it on every terminal exit path
(no-state-file, router-fatal, normal pass). Add `security_lens_cleanup` to the
manifest's `hooks:` block (ADR-056 §4). Declare `provides.result_contract: 2`,
`provides.events: [plugin.result, security_lens.failed]`, `config.router:
{timeout_s:600, max_turns:45}`, and `valid_verdicts: [pass, error]` in the manifest.
Enforce rc ∈ {0, 1}. Cover all paths with tests written first; each SPEC asserts one
observable behavior and carries its `[SPEC-n]` tag in the assertion label. Add a
golden snapshot test (SPEC-15) locking the v2 envelope shape of a passing run.

**SPEC classification rationale.** The design-gate confirmed 3 behaviors already
held at the merge-base (SPEC-5, SPEC-6, SPEC-8 → [guard]) and 11 did not
(SPEC-1–4, 7, 9–14 → [change]). SPEC-15 is a new golden test that does not exist
at merge-base and therefore also [change].

---

```scope
plugins/agent/security-lens/manifest.yaml
plugins/agent/security-lens/plugin.sh
plugins/agent/security-lens/tests/security-lens-test.sh
plugins/agent/security-lens/prompts/security.md
plugins/agent/security-lens/README.md
docs/wiki/plugins/security-lens.md
docs/ARCHITECTURE.md
docs/KEEPERS.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-056-run-cleanup-only-lifecycle.md
docs/adr/ADR-060-stages-return-structure.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-001-plugin-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-028-shared-llm-agent-framework.md
docs/adr/ADR-018-stage-invocation-modes.md
config/event-schema.json
tests/unit/agent-stages-artifact-metadata-symmetry-test.sh
tests/unit/adr-migration-claims-test.sh
tests/unit/plugin-route-source-guard-test.sh
tests/unit/artifact-render-lens-test.sh
tests/unit/tier-resolve-test.sh
tests/unit/core-output-stage-colors-test.sh
tests/unit/lint-contract-scope-derivation-test.sh
tests/unit/scope-redaction-no-tempfile-test.sh
tests/unit/artifact-type-retirement-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/lint-verdict-classify-test.sh
tests/unit/plugin-manifest-contract-audit-test.sh
tests/integration/artifact-contract-test.sh
tests/integration/artifact-chain-test.sh
tests/integration/route-fd-isolation-test.sh
tests/integration/router-sync-preserves-error-artifacts-test.sh
tests/golden/parity/run-fixture.sh
tests/golden/golden-contracts-test.sh
tests/golden/security-lens-pass-artifact.golden
tests/fixtures/templates/crash-resume-minimal.yaml
plugins/tool/output-github-comment/tests/output-test.sh
plugins/tool/output-github-comment/tests/output-stdout-test.sh
.github/issues/keepers-manifest.yaml
scripts/lib/artifact-render.sh
scripts/lib/golden.sh
core/pipeline/runner.sh
scripts/lib/lint-verdict-classify.sh
```

```acceptance
SPEC-1[change]: findings.json carries result_contract:2 at top level on the normal pass exit path
SPEC-2[change]: normal pass exit path emits verdict=pass and disposition=complete
SPEC-3[change]: router-fatal exit path writes a v2 result with verdict=error and disposition=broken
SPEC-4[change]: no-state-file exit path returns rc=1 and writes a v2 result artifact when ZBUILD_ARTIFACT_DIR is set
SPEC-5[guard]: security_lens_cleanup hook is declared in the manifest and the function returns 0
SPEC-6[guard]: manifest declares provides.result_contract: 2
SPEC-7[change]: manifest declares valid_verdicts: [pass, error]
SPEC-8[guard]: plugin.result event is emitted on the normal exit path with plugin=security-lens
SPEC-9[change]: LLM findings are accessible under .data.findings on the normal pass path
SPEC-10[change]: missing scope manifest causes rc=1 (router fail-closed); brace-bearing postamble is recovered by _security_lens_envelope_schema_ok
SPEC-11[change]: manifest declares config.router with timeout_s and max_turns
SPEC-12[change]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE env var takes precedence over manifest config.router.max_turns when set
SPEC-13[change]: manifest declares primary: true on the findings output
SPEC-14[change]: plugin.sh contains no hardcoded artifact path literals (grep for quoted .json/.md with no variable interpolation returns 0)
SPEC-15[change]: a golden snapshot of the security-lens passing-run v2 envelope shape is captured; the snapshot matches on re-run (before/after golden diff proves passing-run behaviour is unchanged after migration)
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
SPEC-15: plugins/agent/security-lens/tests/security-lens-test.sh
```
