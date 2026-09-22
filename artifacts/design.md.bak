# Design: Migrate security-lens to contract v2

## Architectural Decision Summary

**Goal.** Bring `plugins/agent/security-lens` fully into compliance with ADR-054
(stage contract), ADR-056 (run+cleanup-only lifecycle), ADR-060 (stages return
structure), and ADR-063 (interrupt handling / partial output) by adopting the v2
result shape on every exit path.

**Context.** The plugin was the first agent-plugin POC and predated the v2 contract.
It wrote a bare `{findings:[...]}` object with no `result_contract`, no `verdict`, no
`disposition`, and no `reason` field. The `cleanup` hook was missing as a YAML key in
the manifest (only a comment); `valid_verdicts` and `config.router` were absent;
the no-state-file guard returned rc=1 without writing any result artifact; and the
router-fatal branch exited without emitting a v2 envelope. There was also no
interrupt handler for rc=130 per ADR-063 §3. Each gap is a contract violation.

**Decision.** Add a `_security_lens_write_result` helper that atomically writes
`{result_contract:2, verdict, disposition, reason, plugin_id, generated_at,
findings, stub, data:{...}}` and call it on every terminal exit path (no-state-file,
router-fatal, interrupt rc=130, normal pass). Add `cleanup: security_lens_cleanup`
to the manifest `hooks:` block. Declare `provides.result_contract: 2`,
`provides.events: [plugin.result, security_lens.failed]`, `provides.role:
security-auditor`, `config.router: {timeout_s:600, max_turns:45}`, and
`valid_verdicts: [pass, error]` in the manifest. Add `_security_lens_interrupt_handler`
registered as TERM/INT trap around the model call. Enforce rc ∈ {0, 1, 130}. Cover
all paths with tests written first; each SPEC asserts one observable behavior.

**Status.** Implementation fully committed at HEAD (f4ffd8cc). All SPECs 1–20 are
exercised in the test file; golden snapshot committed. The final commit refined the
test's manifest-section extraction (awk-scoped blocks for SPEC-5/7/11) and changed
SPEC-12 to prove the override reaches the claude invocation via argv capture rather
than env-var capture — the observable behaviors are unchanged.

---

```scope
plugins/agent/security-lens/manifest.yaml
plugins/agent/security-lens/plugin.sh
plugins/agent/security-lens/tests/security-lens-test.sh
plugins/agent/security-lens/prompts/security.md
plugins/agent/security-lens/README.md
docs/wiki/plugins/security-lens.md
docs/wiki/Writing-Plugins.md
docs/wiki/Plugins.md
docs/ARCHITECTURE.md
docs/KEEPERS.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-056-run-cleanup-only-lifecycle.md
docs/adr/ADR-060-stages-return-structure.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
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
tests/unit/test-author-test.sh
tests/unit/core-event-bus-test.sh
tests/unit/review-report-plugin-test.sh
tests/unit/runner-post-stage-capability-test.sh
tests/unit/review-aggregator-test.sh
tests/unit/lifecycle-testfile-deny-role-test.sh
tests/unit/core-detect-platforms-a-test.sh
tests/integration/artifact-contract-test.sh
tests/integration/artifact-chain-test.sh
tests/integration/route-fd-isolation-test.sh
tests/integration/router-sync-preserves-error-artifacts-test.sh
tests/integration/stage-io-ordering-invariant-test.sh
tests/integration/core-pipeline-runner-test.sh
tests/integration/template-constructs-test.sh
tests/golden/parity/run-fixture.sh
tests/golden/golden-contracts-test.sh
tests/golden/security-lens-pass-artifact.golden
tests/fixtures/templates/crash-resume-minimal.yaml
tests/e2e/zbuild-cli-verbs-test.sh
tests/e2e/redaction-edge-cases-test.sh
tests/e2e/crash-resume-test.sh
tests/e2e/injection-guard-test.sh
plugins/tool/output-github-comment/tests/output-test.sh
plugins/tool/output-github-comment/tests/output-stdout-test.sh
plugins/tool/test/tests/test-test.sh
.github/issues/keepers-manifest.yaml
scripts/lib/artifact-render.sh
scripts/lib/golden.sh
scripts/lib/lint-verdict-classify.sh
scripts/lib/llm-agent.sh
scripts/lib/lint-llm-envelope.sh
scripts/lib/test-output-sanitize.sh
scripts/lib/manifest-graph.sh
scripts/lib/lint-contract.sh
core/pipeline/runner.sh
core/router/route.sh
core/state/resume.sh
core/output/stage-io.sh
core/output/stage-colors.sh
legacy/migrated/security-lens.md
```

```acceptance
SPEC-1[change]: findings.json carries result_contract:2 at top level on the normal pass exit path
SPEC-2[change]: normal pass exit path emits verdict=pass and disposition=complete
SPEC-3[change]: router-fatal exit path writes a v2 result with verdict=error and disposition=broken
SPEC-4[change]: no-state-file exit path returns rc=1 and writes a v2 result artifact when ZBUILD_ARTIFACT_DIR is set
SPEC-5[change]: security_lens_cleanup hook is declared as a YAML key under hooks: in the manifest (not merely a comment) and the function returns 0
SPEC-6[change]: manifest declares provides.result_contract: 2 under the provides: section
SPEC-7[change]: manifest declares valid_verdicts: [pass, error] under the config: section
SPEC-8[change]: plugin.result event is emitted on the normal exit path with plugin=security-lens
SPEC-9[change]: LLM findings are accessible under .data.findings on the normal pass path
SPEC-10[change]: missing scope manifest causes rc=1 (router fail-closed); brace-bearing postamble is recovered by _security_lens_envelope_schema_ok
SPEC-11[change]: manifest declares config.router with timeout_s and max_turns
SPEC-12[change]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE env var takes precedence over manifest config.router.max_turns when set; proven by argv capture showing --max-turns 7 reaches claude when override=7
SPEC-13[change]: manifest declares primary: true on the findings output
SPEC-14[change]: plugin.sh contains no hardcoded artifact path literals; assertion uses `_spec14_bad=$(grep -cE '"[^"$]*\.(json|md)"' "$_spec14_plugin" 2>/dev/null || true)` — NOT `|| echo 0` (grep -c outputs "0" on no match and exits rc=1; `|| echo 0` appends a second "0", producing "0\n0")
SPEC-15[change]: a golden snapshot of the security-lens passing-run v2 envelope shape is captured; assertion uses `assert_eq "[SPEC-15] ..." "0" "$_spec15_rc"` on a directly-executed line where `_spec15_rc` is the return code from `assert_golden "security-lens-pass-artifact" "$_spec15_expected_keys"` — NOT inside an if/else block (the acceptance-gate static grep requires the assert_eq form)
SPEC-16[change]: manifest declares provides.events containing plugin.result and security_lens.failed; test confirms both event names appear under the provides.events key in the manifest
SPEC-17[change]: manifest declares provides.role: security-auditor; test confirms the value appears under the provides.role key in the manifest
SPEC-18[change]: interrupt handler _security_lens_interrupt_handler exists; rc=130 from route_to_model returns plugin rc=130 and writes a v2 result with verdict=error and disposition=interrupted; direct handler invocation and kill -TERM both produce the same artifact shape
SPEC-19[change]: canary — all preceding assertions in the test file have FAIL==0 at the point of this check
SPEC-20[change]: manifest input entries declare only id and required: fields — no from:, path:, or type: keys in the inputs block
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
SPEC-15: tests/golden/golden-contracts-test.sh
SPEC-16: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-17: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-18: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-19: plugins/agent/security-lens/tests/security-lens-test.sh
SPEC-20: plugins/agent/security-lens/tests/security-lens-test.sh
```
