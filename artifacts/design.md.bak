# Design: Migrate review-report plugin to contract v2 (#1843)

## Architectural decision summary

**Goal.** Bring `plugins/agent/review-report` up to the ADR-054 v2 result contract: write a `review-report-result.json` sidecar on every terminal exit path, declare `result_contract: 2` and a `config.router:` block in the manifest, replace the bare `extract_first_json_object` lens-parse path with the schema-gated `_llm_envelope_parse` recovery path, and inject router budget guidance into each lens prompt.

**Context.** Twenty-five plugins are migrating one at a time (#1833–#1849). The engine already reads both v1 and v2 results (`_ZBUILD_CONTRACT_MIN=1`, `_ZBUILD_CONTRACT_MAX=2` in `core/contract/version.sh`). The review-report plugin currently: (1) never writes a sidecar result file, (2) uses `extract_first_json_object` bare in `_rr_parse_lens_out` (LAST-wins, no schema recovery), (3) never injects budget guidance, and (4) does not source `scripts/lib/llm-agent.sh`.

**Decision.** Implement all four sub-changes within the plugin boundary; no engine or template changes are required. Pattern source: `_design_write_result` from `plugins/agent/design/plugin.sh`, `_design_budget_guidance` likewise, and the `_llm_envelope_parse --schema-gate` pattern from `plugins/agent/security-lens/plugin.sh:140–148`. The result sidecar is `$artifact_dir/review-report-result.json` — distinct from the advisory `review-report.json`.

---

```scope
plugins/agent/review-report/manifest.yaml
plugins/agent/review-report/plugin.sh
plugins/agent/review-report/lib/lenses.sh
tests/unit/review-report-plugin-test.sh
tests/golden/review-report-pass.json
tests/integration/review-report-advisory-flow-test.sh
tests/unit/call-graph-evidence-test.sh
tests/unit/review-lens-report-merge-base-bundle-test.sh
tests/unit/review-aggregator-test.sh
tests/unit/tier-resolve-test.sh
tests/unit/pr-open-advisory-review-test.sh
docs/wiki/plugins/review-report.md
docs/adr/ADR-038-adversarial-multilens-review-report.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/adr/ADR-028-shared-llm-agent-framework.md
scripts/lib/llm-agent.sh
core/contract/version.sh
```

---

```acceptance
SPEC-1[change]: manifest declares result_contract:2 under provides: and a config.router: block with timeout_s and max_turns
SPEC-2[change]: _rr_write_result helper exists in plugin.sh and writes a conformant v2 result file (result_contract:2, verdict, disposition, reason) at $artifact_dir/review-report-result.json
SPEC-3[change]: v2 result file written with verdict=error and disposition=broken on the missing state_file exit path
SPEC-4[change]: v2 result file written with verdict=error and disposition=broken on the missing out_json exit path
SPEC-5[change]: v2 result file written with verdict=pass and disposition=complete on the normal completion path
SPEC-6[change]: _rr_budget_guidance helper exists in plugin.sh and injects a TURN BUDGET block sourced from _route_resolve_max_turns and _route_resolve_timeout into each lens prompt
SPEC-7[change]: _rr_lens_envelope_schema_ok predicate exists and validates {score:number, findings:array} shape
SPEC-8[change]: _rr_parse_lens_out routes through _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok instead of bare extract_first_json_object; extract_first_json_object no longer appears in lenses.sh
SPEC-9[guard]: _rr_run_inner returns 0 and advisory review-report.json is still written on normal completion (advisory contract preserved)
SPEC-10[guard]: 11 independent LLM calls are still made (one per lens) and findings are still aggregated and de-duped

WIRING: plugins/agent/review-report/plugin.sh

TESTFILES:
SPEC-1: tests/unit/review-report-plugin-test.sh
SPEC-2: tests/unit/review-report-plugin-test.sh
SPEC-3: tests/unit/review-report-plugin-test.sh
SPEC-4: tests/unit/review-report-plugin-test.sh
SPEC-5: tests/unit/review-report-plugin-test.sh
SPEC-6: tests/unit/review-report-plugin-test.sh
SPEC-7: tests/unit/review-report-plugin-test.sh
SPEC-8: tests/unit/review-report-plugin-test.sh
SPEC-9: tests/unit/review-report-plugin-test.sh
SPEC-10: tests/unit/review-report-plugin-test.sh
```
