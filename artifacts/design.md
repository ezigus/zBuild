# Design: Migrate review-report plugin to contract v2 (#1843)

## Architectural decision summary

**Goal.** Bring the review-report plugin into full conformance with the Phase 0
result contract (ADR-054/ADR-055): emit `result_contract:2` with
`verdict/disposition/reason` on every exit path, replace the bare
`extract_first_json_object` parse with schema-gated `_llm_envelope_parse`, inject
router-derived budget guidance into lens prompts (ADR-063 §1), and declare the
`config.router` block and `cleanup:~` null sentinel in the manifest.

**Context.** All four source files (`manifest.yaml`, `plugin.sh`, `lib/lenses.sh`,
`tests/unit/review-report-plugin-test.sh`) were already migrated in commits
`ae0c64c5` and `60444768` on branch `zbuild/issue-1843-ci`. The design stage's job
is to enumerate the full impact surface — including tests, docs, golden files, and
cross-references — so the implement stage has an explicit, complete file list to
validate against.

**Decision.** The change is plugin-boundary-contained: no engine files change, no
new stage is added, and no template is modified. The result sidecar
`review-report-result.json` is a new required output declared entirely within the
plugin's manifest; the v2 result schema is written by `_rr_write_result` (copied
from the teardown pattern). ADR-028 §"Not yet migrated" explicitly names
review-report as using bare `extract_first_json_object` — that note becomes stale
after this migration and `docs/adr/ADR-028-shared-llm-agent-framework.md` is in
scope for a prose update. The wiki page `docs/wiki/plugins/review-report.md`
must reflect the new manifest shape (result_contract:2, config.router, outputs).

```scope
plugins/agent/review-report/manifest.yaml
plugins/agent/review-report/plugin.sh
plugins/agent/review-report/lib/lenses.sh
tests/unit/review-report-plugin-test.sh
tests/golden/review-report-pass.json
docs/wiki/plugins/review-report.md
docs/adr/ADR-001-plugin-contract.md
docs/adr/ADR-028-shared-llm-agent-framework.md
docs/adr/ADR-038-adversarial-multilens-review-report.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-063-budget-disclosure-and-partial-output.md
tests/integration/review-report-advisory-flow-test.sh
tests/integration/merge-policy-auto-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/unit/call-graph-evidence-test.sh
tests/unit/review-lens-report-merge-base-bundle-test.sh
tests/unit/review-aggregator-test.sh
tests/unit/review-aggregator-roster-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/unit/adr-migration-claims-test.sh
tests/unit/pr-open-advisory-review-test.sh
tests/unit/template-simple-yaml-test.sh
tests/unit/tier-resolve-test.sh
scripts/lib/llm-agent.sh
scripts/lib/artifact-render.sh
core/contract/version.sh
core/plugin-registry/manifest-validation.sh
config/event-schema.json
config/templates/simple.yaml
```

```acceptance
SPEC-1[change]: manifest declares result_contract:2 under provides: and a config.router: block with timeout_s and max_turns
SPEC-2[change]: _rr_write_result helper exists in plugin.sh and writes a conformant v2 result file (result_contract:2, verdict, disposition, reason)
SPEC-3[change]: review_report_run writes verdict=error / disposition=broken result when state_file argument is missing
SPEC-4[change]: _rr_run_inner writes verdict=error / disposition=broken result when out_json argument is missing
SPEC-5[change]: _rr_run_inner writes verdict=pass / disposition=complete result on normal completion (all lenses rc=0)
SPEC-6[change]: _rr_budget_guidance helper exists and injects a TURN BUDGET block into lens prompts via _rr_fanout_lenses
SPEC-7[change]: _rr_lens_envelope_schema_ok predicate exists in lenses.sh and validates {score:number, findings:array}
SPEC-8[change]: extract_first_json_object is absent from lenses.sh; _rr_parse_lens_out calls _llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok
SPEC-9[guard]: _rr_run_inner returns 0 (advisory contract) and review-report.json is written on normal completion
SPEC-10[guard]: 11 independent LLM calls are made (one per lens); advisory report has 11 lens sections
SPEC-11[guard]: manifest declares valid_verdicts: [] (advisory plugin writes no verdict to the pipeline channel)
SPEC-12[guard]: manifest first output (review_report) retains primary: true
SPEC-13[guard]: manifest declares provides.role: review_report and all four provides.events
SPEC-14[guard]: manifest has no active cleanup hook (cleanup: ~ null sentinel only); plugin.sh defines no review_report_cleanup function
SPEC-15[change]: review_report_run reads scope_manifest path from ZBUILD_STAGE_INPUTS via jq -r .inputs.scope_manifest (no hardcoded state_dir path concatenation)
SPEC-16[change]: disposition=exhausted (verdict=pass) is written when at least one lens subshell returns non-zero rc
SPEC-17[guard]: plugin.sh constructs no hardcoded state_dir path concatenation for any declared input filename
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
