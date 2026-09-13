# Design: Migrate review-report plugin to contract v2 (#1843)

## Architectural decision summary

**Goal.** Bring `plugins/agent/review-report` up to the ADR-054 v2 result contract: write a `review-report-result.json` sidecar on every terminal exit path, declare `result_contract: 2` and a `config.router:` block in the manifest, replace the bare `extract_first_json_object` lens-parse path with the schema-gated `_llm_envelope_parse` recovery path, inject router budget guidance into each lens prompt, add `ZBUILD_STAGE_INPUTS` reading for all name-matched inputs, and emit `disposition: exhausted` when lens subshells signal budget exhaustion.

**Context.** Twenty-five plugins are migrating one at a time (#1833–#1849). The engine already reads both v1 and v2 results (`_ZBUILD_CONTRACT_MIN=1`, `_ZBUILD_CONTRACT_MAX=2` in `core/contract/version.sh`). The review-report plugin currently: (1) never writes a sidecar result file; (2) uses bare `extract_first_json_object` in `_rr_parse_lens_out` (LAST-wins, no schema recovery); (3) never injects budget guidance; (4) does not source `scripts/lib/llm-agent.sh`; (5) constructs the scope_manifest path as `$state_dir/scope-manifest.md` rather than reading from `ZBUILD_STAGE_INPUTS`; (6) does not read plan, diff_patch, or intake_goal from `ZBUILD_STAGE_INPUTS`. The manifest already has `valid_verdicts: []`, `primary: true`, `provides.role`, `provides.events`, and no `cleanup` hook — those become guard SPECs only.

**Decision.** Implement all sub-changes within the plugin boundary; no engine or template changes required. Pattern sources: `_design_write_result` and `_design_budget_guidance` from `plugins/agent/design/plugin.sh`; `_llm_envelope_parse --schema-gate` from `plugins/agent/security-lens/plugin.sh:140–148`. Result sidecar is `$artifact_dir/review-report-result.json` — distinct from the advisory `review-report.json`. All four declared inputs (scope_manifest, plan, diff_patch, intake_goal) are read from `ZBUILD_STAGE_INPUTS` when available, falling back to state_dir construction; after the change, plugin.sh must contain no hardcoded state_dir path construction for any declared input (blanket grep-asserted as SPEC-17). For `disposition: exhausted` (ADR-063 §3): track a `_rr_any_lens_failed` flag across the fan-out; if any lens subshell returns non-zero rc, write `verdict=pass, disposition=exhausted` instead of `disposition=complete` (advisory verdict stays pass). No `cleanup` hook is declared or implemented — the engine emits `plugin.cleanup.absent` by ADR-001 §2 contract.

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
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/plugin-route-source-guard-test.sh
docs/wiki/plugins/review-report.md
docs/adr/ADR-038-adversarial-multilens-review-report.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
docs/adr/ADR-028-shared-llm-agent-framework.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
scripts/lib/llm-agent.sh
core/contract/version.sh
```

---

```acceptance
SPEC-1[change]: manifest declares result_contract:2 under provides: and a config.router: block with timeout_s and max_turns
SPEC-2[change]: _rr_write_result helper exists in plugin.sh and writes a conformant v2 result file (result_contract:2, verdict, disposition, reason) at $artifact_dir/review-report-result.json
SPEC-3[change]: v2 result file written with verdict=error and disposition=broken on the missing state_file exit path
SPEC-4[change]: v2 result file written with verdict=error and disposition=broken on the missing out_json exit path
SPEC-5[change]: v2 result file written with verdict=pass and disposition=complete on normal completion (all lens subshells return rc=0)
SPEC-6[change]: _rr_budget_guidance helper exists in plugin.sh and injects a TURN BUDGET block sourced from _route_resolve_max_turns and _route_resolve_timeout into each lens prompt
SPEC-7[change]: _rr_lens_envelope_schema_ok predicate exists and validates {score:number, findings:array} shape
SPEC-8[change]: _rr_parse_lens_out routes through _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok instead of bare extract_first_json_object; extract_first_json_object no longer appears in lenses.sh
SPEC-9[guard]: _rr_run_inner returns 0 and advisory review-report.json is still written on normal completion (advisory contract preserved)
SPEC-10[guard]: 11 independent LLM calls are still made (one per lens) and findings are still aggregated and de-duped
SPEC-11[guard]: manifest declares valid_verdicts: [] (advisory — writes no verdict to the engine's pipeline verdict channel)
SPEC-12[guard]: manifest outputs first entry (review_report) retains primary: true after migration
SPEC-13[guard]: manifest provides.role: review_report and all four declared provides.events are present after migration
SPEC-14[guard]: no cleanup hook key in manifest.hooks and no review_report_cleanup function in plugin.sh (cleanup absent-and-recorded: engine emits plugin.cleanup.absent by ADR-001 §2)
SPEC-15[change]: review_report_run reads scope_manifest input path from ZBUILD_STAGE_INPUTS index when available, falling back to $state_dir/scope-manifest.md; the plugin calls jq -r '.inputs.scope_manifest' "$ZBUILD_STAGE_INPUTS" for this input
SPEC-16[change]: v2 result sidecar written with verdict=pass and disposition=exhausted when at least one lens subshell returns non-zero rc (partial advisory results signalled per ADR-063 §3); verdict stays pass to preserve advisory contract
SPEC-17[change]: plugin.sh constructs no hardcoded artifact path from state_dir for any of the four declared input ids (scope_manifest, plan, diff_patch, intake_goal) — a blanket grep over plugin.sh confirms no occurrence of state_dir concatenated with any declared input filename (scope-manifest.md, plan.json, diff.patch, intake.md, intake-goal.md); all inputs are sourced exclusively from ZBUILD_STAGE_INPUTS when the index is present

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
SPEC-11: tests/unit/review-report-plugin-test.sh
SPEC-12: tests/unit/review-report-plugin-test.sh
SPEC-13: tests/unit/review-report-plugin-test.sh
SPEC-14: tests/unit/review-report-plugin-test.sh
SPEC-15: tests/unit/review-report-plugin-test.sh
SPEC-16: tests/unit/review-report-plugin-test.sh
SPEC-17: tests/unit/review-report-plugin-test.sh
```

LOOP_COMPLETE
