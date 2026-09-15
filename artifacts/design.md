# Design: Migrate security-lens to contract v2

## Architectural decision summary

**Goal.** Bring `plugins/agent/security-lens` into full ADR-054/ADR-056/ADR-060
compliance: emit a `result_contract:2` artifact (with `verdict`, `disposition`,
`reason`, and domain data nested under `.data`) on every terminal exit path,
declare router budgets and events in the manifest, fix `rc∈{0,1}`, add the
cleanup hook, assert no new hardcoded artifact paths, and cover all paths with
tests written first.

**Context.** security-lens was the Phase 0 migration POC. Its findings.json
uses a v1 shape (`schema_version:1`, all fields at top level). The engine now
reads `result_contract` to dispatch v2 logic; plugins that don't declare it fall
through to legacy paths. The `valid_verdicts: []` claim tells the engine "this
plugin never emits a verdict", which is wrong once the plugin writes
`verdict=pass` / `verdict=error`. Two return paths still use `rc=2`, which
ADR-054 §4 prohibits. The manifest is also missing `config.router:` budget
declarations and `provides.events:`, both required by ADR-017 §11.

**Decision.** Add `_security_lens_write_result` (mirrors `_scv_write` in
spec-coverage) to write `{result_contract:2, verdict, disposition, reason,
data:{plugin_id, generated_at, findings, stub}}` atomically. Rewrite all
terminal paths through this helper. Fix `rc=2 → rc=1`. Add
`security_lens_cleanup`. Update the manifest with `result_contract:2`,
`provides.events:`, `config.router:` (timeout_s + max_turns), and
`valid_verdicts:[pass,error]`. Update the renderer (`render_lens_md`) to read
`(.data.findings // .findings // [])` for v1/v2 compatibility. Update
`artifact-chain-test.sh` to read findings via the v2-compatible path.
Tests are written first (TDD); every SPEC is tagged in assertions.

---

```scope
plugins/agent/security-lens/manifest.yaml
plugins/agent/security-lens/plugin.sh
plugins/agent/security-lens/tests/security-lens-test.sh
scripts/lib/artifact-render.sh
tests/unit/artifact-render-lens-test.sh
tests/integration/artifact-chain-test.sh
docs/wiki/plugins/security-lens.md
```

---

```acceptance
SPEC-1[change]: findings.json carries result_contract:2 at top level on the normal (pass) exit path
SPEC-2[change]: normal exit path sets verdict=pass and disposition=complete
SPEC-3[change]: router-fatal path writes result_contract:2 with verdict=error and disposition=broken and returns rc=1
SPEC-4[change]: no-state-file path (security_lens_run) writes a v2 result and returns rc=1, not rc=2
SPEC-5[change]: security_lens_cleanup function is declared and returns 0
SPEC-6[change]: manifest declares provides.result_contract: 2
SPEC-7[change]: manifest declares valid_verdicts: [pass, error]
SPEC-8[guard]: plugin.result event continues to be emitted on the normal path with plugin=security-lens
SPEC-9[guard]: parsed findings remain accessible under .data.findings in the v2 artifact
SPEC-10[guard]: router fail-closed is preserved — missing scope manifest returns rc=1
SPEC-11[change]: manifest declares config.router block with timeout_s and max_turns
SPEC-12[guard]: ZBUILD_ROUTER_MAX_TURNS_OVERRIDE takes precedence over manifest config.router.max_turns when set (template override wins per #1816)
SPEC-13[guard]: manifest declares primary: true on the findings output entry
SPEC-14[guard]: plugin.sh constructs no hardcoded artifact path literals beyond the manifest-declared output basenames (security-findings.json and security-lens-summary.md) — confirmed by grep

WIRING: plugins/agent/security-lens/manifest.yaml

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
