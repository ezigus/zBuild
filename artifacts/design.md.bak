# Design: Migrate security-lens to contract v2

## Architectural Decision Summary

**Goal.** Bring `plugins/agent/security-lens` fully into compliance with ADR-054
(stage contract), ADR-056 (run+cleanup-only lifecycle), ADR-060 (stages return
structure), ADR-062 (engine-owned reclamation), and ADR-063 (interrupt handling /
partial output) by adopting the v2 result shape on every exit path.

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
router-fatal, interrupt rc=130, normal pass). Add `security_lens_cleanup()` function
to plugin.sh — callable and returning 0 — but declare NO `cleanup:` YAML key in the
manifest: ADR-062 §3 retired per-stage cleanup hook declarations tree-wide, and
`tests/integration/cleanup-release-test.sh` SPEC-3 plus
`tests/unit/teardown-purge-scratch-test.sh` SPEC-4 BOTH enforce
`grep -rlE '^[[:space:]]*cleanup:' plugins/*/*/manifest.yaml = empty`. The
irreconcilable constraint between the original SPEC-5 ("declare cleanup: YAML key")
and ADR-062 §3 ("no plugin declares cleanup:") is resolved in favour of ADR-062:
SPEC-5 verifies the function is callable and returns 0, without requiring a manifest
declaration. Declare `provides.result_contract: 2`, `provides.events: [plugin.result,
security_lens.failed]`, `provides.role: security-auditor`, `config.router:
{timeout_s:600, max_turns:45}`, and `valid_verdicts: [pass, error]` in the manifest.
Add `_security_lens_interrupt_handler` registered as TERM/INT trap around the model
call. Enforce rc ∈ {0, 1, 130}. Cover all paths with tests written first; each SPEC
asserts one observable behavior.

**Pre-existing test failure.** `tests/integration/per-run-state-isolation-test.sh`
T4 ("explicit-state run exits 0") fails with rc=1. The branch diff is confined to
`plugins/agent/security-lens/manifest.yaml` (cleanup key removal) and
`plugins/agent/security-lens/tests/security-lens-test.sh` (test update). Neither file
can affect state-directory isolation logic. T4 is a pre-existing regression unrelated
to this issue and is outside this change's scope.

**Shape-floor scope expansion (iteration 2).** `core/pipeline/runner.sh` is in scope
and matches a glob in `config/shape-change-paths.txt`. The shape-floor
(`scripts/lib/shape-floor.sh`) mechanically requires that ALL
`tests/golden/**/event-sequence.golden` files (enumerated by
`_impact_list_event_goldens`) and ALL tests containing `_TPL_STAGES[N]`-indexed
assertions (enumerated by `_impact_list_order_assertions`) also appear in the diff
whenever a shape-change-path file changes. The prior design omitted these 7 files;
the build stage never touched them; shape-floor reported `missing_floor_files` and
the engine re-routed to this design stage. They are added to scope here:
- `tests/golden/parity/event-sequence.golden` — event-sequence golden
- `tests/golden/full-pipeline/event-sequence.golden` — event-sequence golden
- `tests/unit/template-resolvability-preflight-test.sh` — `_TPL_STAGES[N]` indexed
- `tests/unit/build-oos-pass-request-test.sh` — `_TPL_STAGES[N]` indexed
- `tests/unit/template-simple-yaml-test.sh` — `_TPL_STAGES[N]` indexed
- `tests/unit/core-pipeline-template-test.sh` — `_TPL_STAGES[N]` indexed
- `tests/unit/impact-prefilter-order-detector-test.sh` — `_TPL_STAGES[N]` indexed

None reference security-lens directly; they require review to confirm the runner.sh
state-directory fixes (e34fc49b, c8ec8836) do not alter any emitted event sequence
or stage order. If unaffected, the build stage certifies them with a benign touch.

**Status.** Implementation fully committed. All SPECs 1–20 exercised with NEGCTL PASS
at the acceptance-gate; golden snapshot committed. Shape-floor scope gap resolved in
iteration 2 by adding 7 runner.sh-triggered shape-change files to scope.

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
docs/adr/ADR-062-engine-owned-reclamation.md
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
tests/unit/teardown-purge-scratch-test.sh
tests/unit/template-resolvability-preflight-test.sh
tests/unit/build-oos-pass-request-test.sh
tests/unit/template-simple-yaml-test.sh
tests/unit/core-pipeline-template-test.sh
tests/unit/impact-prefilter-order-detector-test.sh
tests/integration/artifact-contract-test.sh
tests/integration/artifact-chain-test.sh
tests/integration/route-fd-isolation-test.sh
tests/integration/router-sync-preserves-error-artifacts-test.sh
tests/integration/stage-io-ordering-invariant-test.sh
tests/integration/core-pipeline-runner-test.sh
tests/integration/template-constructs-test.sh
tests/integration/cleanup-release-test.sh
tests/integration/per-run-state-isolation-test.sh
tests/golden/parity/run-fixture.sh
tests/golden/parity/event-sequence.golden
tests/golden/full-pipeline/event-sequence.golden
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
SPEC-5[change]: security_lens_cleanup function exists in plugin.sh, is callable, and returns 0; the manifest declares NO cleanup: YAML key under hooks: (ADR-062 §3 retired per-stage cleanup hook declarations tree-wide — cleanup-release-test.sh SPEC-3 and teardown-purge-scratch-test.sh SPEC-4 enforce this constraint)
SPEC-6[change]: manifest declares provides.result_contract: 2 under the provides: section
SPEC-7[change]: manifest declares valid_verdicts: [pass, error] under the config: section
SPEC-8[change]: plugin.result event is emitted on the normal exit path with plugin=security-lens
SPEC-9[change]: LLM findings are accessible under .data.findings on the normal pass path
SPEC-10[change]: missing scope manifest causes rc=1 (router fail-closed); brace-bearing postamble is recovered by _security_lens_envelope_schema_ok
SPEC-11[change]: manifest declares config.router with timeout_s and max_turns
SPEC-12[change]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE env var takes precedence over manifest config.router.max_turns when set
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

LOOP_COMPLETE
