# Design: Migrate security-lens to contract v2

## Architectural Decision Summary

**Goal.** Bring `plugins/agent/security-lens` fully into compliance with ADR-054
(stage contract), ADR-056 (run+cleanup-only lifecycle), and ADR-060 (stages return
structure) by adopting the v2 result shape on every exit path.

**Context.** The plugin was the first agent-plugin POC and predates the v2 contract.
It wrote a bare `{findings:[...]}` object with no `result_contract`, no `verdict`, no
`disposition`, and no `reason` field. The `cleanup` hook function existed in plugin.sh
but was never declared as a YAML key in the manifest (only a comment); `valid_verdicts`
and `config.router` were absent from the manifest; the no-state-file guard returned
rc=1 without writing any result artifact; and the router-fatal branch exited without
emitting a v2 envelope. Each gap is a contract violation that ADR-054 §4–6 enforces.

**Decision.** Extend `plugin.sh` with a `_security_lens_write_result` helper that
atomically writes `{result_contract:2, verdict, disposition, reason, plugin_id,
generated_at, findings, stub, data:{...}}` and call it on every terminal exit path
(no-state-file, router-fatal, normal pass). Add `cleanup: security_lens_cleanup` to
the manifest's `hooks:` block as a proper YAML key (not a comment). Declare
`provides.result_contract: 2`, `provides.events: [plugin.result, security_lens.failed]`,
`config.router: {timeout_s:600, max_turns:45}`, and `valid_verdicts: [pass, error]`
in the manifest. Enforce rc ∈ {0, 1}. Cover all paths with tests written first; each
SPEC asserts one observable behavior and carries its `[SPEC-n]` tag in the assertion
label.

**SPEC-14 assertion idiom (CRITICAL):** The assertion MUST use
`grep -E '"[^"$]*\.(json|md)"' "$_spec14_plugin" | wc -l` and store the result in
`_spec14_bad`. Do NOT use `grep -cE '"[^"$]*\.(json|md)"' ... || echo 0` — when grep
finds no matches it exits rc=1 AND outputs "0"; the `|| echo 0` then appends a second
"0", producing the two-line string `"0\n0"` in the variable; `assert_eq "0" "0\n0"`
then fails even though there are no matches. The `| wc -l` form returns "0" (one line,
no trailing content) when there are no matches and never invokes a fallback.

**SPEC-15 assertion idiom (CRITICAL):** The `[SPEC-15]` assertion tag MUST appear on
a directly-executed `assert_eq` line, not inside an `if/else/fi` block. The acceptance-
gate does a static grep for the tag; a tag that only appears inside a conditional
branch is unreachable by static scan and the gate reports "asserts: <none found>". Use:
```bash
set +e
assert_golden "security-lens-pass-artifact" "$_spec15_expected_keys"
_spec15_rc=$?
set -e
assert_eq "[SPEC-15] security-lens v2 envelope golden matches expected key set" "0" "$_spec15_rc"
```

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
tests/integration/artifact-contract-test.sh
tests/integration/artifact-chain-test.sh
tests/integration/route-fd-isolation-test.sh
tests/integration/router-sync-preserves-error-artifacts-test.sh
tests/integration/stage-io-ordering-invariant-test.sh
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
SPEC-5[guard]: ANSI escape bytes are stripped from the input text before the assembled string reaches route_to_model
SPEC-6[guard]: genuine security content in the input text survives the sanitize step and reaches route_to_model intact
SPEC-7[change]: manifest declares valid_verdicts: [pass, error]
SPEC-8[guard]: plugin.result event is emitted on the normal exit path with plugin=security-lens
SPEC-9[change]: LLM findings are accessible under .data.findings on the normal pass path
SPEC-10[change]: missing scope manifest causes rc=1 (router fail-closed); brace-bearing postamble is recovered by _security_lens_envelope_schema_ok
SPEC-11[change]: manifest declares config.router with timeout_s and max_turns
SPEC-12[change]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE env var takes precedence over manifest config.router.max_turns when set
SPEC-13[change]: manifest declares primary: true on the findings output
SPEC-14[change]: plugin.sh contains no hardcoded artifact path literals; assertion uses `_spec14_bad=$(grep -E '"[^"$]*\.(json|md)"' "$_spec14_plugin" | wc -l)` followed by `assert_eq "[SPEC-14] ..." "0" "$_spec14_bad"` — NOT `grep -cE ... || echo 0` which produces "0\n0" on no-match
SPEC-15[change]: a golden snapshot of the security-lens passing-run v2 envelope shape is captured; assertion uses `assert_eq "[SPEC-15] ..." "0" "$_spec15_rc"` where `_spec15_rc` is the return code from `assert_golden "security-lens-pass-artifact" "$_spec15_expected_keys"` — NOT inside an if/else block, so the gate can find the [SPEC-15] tag via static grep
SPEC-16[change]: the manifest hooks block declares cleanup: security_lens_cleanup as a YAML key (not merely a comment); test verifies the key is present under hooks: by parsing the YAML structure
SPEC-17[change]: manifest declares provides.result_contract: 2; test verifies the value is present under the provides: section by checking the YAML path provides.result_contract
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
```

LOOP_COMPLETE
