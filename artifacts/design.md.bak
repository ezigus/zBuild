# Design: migrate review-aggregator to contract v2 (#1842)

## Architectural decision summary

**Goal.** Bring `plugins/agent/review-aggregator` into full compliance with the
ADR-055 inter-stage data contract v2 (the same migration wave as #1840
review-lens, #1849, etc.).

**Context.** The plugin currently writes only `review-report.json` (no v2
`result_contract`/`verdict`/`disposition`/`reason` envelope), declares
`valid_verdicts: []` (the empty sentinel that means "we haven't migrated yet"),
marks `review_report_md` as `required: false`, reads its lens inputs via a
`lens-*.json` glob instead of the engine-resolved `ZBUILD_STAGE_INPUTS` path
(ADR-055 §1.4, which explicitly retires that glob), and registers no SIGTERM/SIGINT
trap.  Every one of these gaps was acceptable before the v2 wave; none is after it.

**Decision.** Four-step migration following the established pattern from
`review-lens` (#1840):

1. **New test file first** (`review-aggregator-v2-test.sh`) — all assertions red
   at baseline.
2. **Manifest** — add `provides.result_contract: 2`, change `valid_verdicts` from
   `[]` to `[complete, degraded]`, change `review_report_md.required` to `true`,
   add the cleanup-absent comment (mirrors review-lens).
3. **Plugin** — add `_ra_input` (mirrors `_rl_input`), add
   `_ra_collect_lenses_inputs` (reads `.inputs.lens_result` array from
   `ZBUILD_STAGE_INPUTS`), remove `_ra_collect_lenses_glob`, update discovery
   order to ZBUILD_STAGE_INPUTS → roster, embed v2 fields
   (`result_contract:2 / verdict:complete / disposition:complete / reason`) in the
   written `review-report.json`, write `review_report_md` on every terminal exit
   path (including the empty-lens early path), register a SIGTERM/SIGINT trap that
   writes `verdict:degraded / disposition:interrupted` and summary then re-raises.
4. **Existing tests** — update SPEC-3 in `review-aggregator-test.sh` (invert
   "no verdict field" → "verdict == complete"), add ZBUILD_STAGE_INPUTS fixture
   setup for SPEC-1/SPEC-6/SPEC-7/SPEC-8, add summary-exists assertions to SPEC-6
   and SPEC-8; update `review-aggregator-roster-test.sh` SPEC-3 (glob fallback
   test becomes "no ZBUILD_STAGE_INPUTS + no group env → empty report, rc 0").

The aggregator makes no LLM calls, so `router_reason_disposition` is not needed
and no `router:` section is added.  Valid verdicts are `complete` (ran to
completion) and `degraded` (interrupted); there is no model-call failure path.
The rendered `review-report.md` doubles as the ADR-055 §9 stage summary —
writing it unconditionally satisfies both concerns without a separate
`stage_summary_write` call.

```scope
plugins/agent/review-aggregator/manifest.yaml
plugins/agent/review-aggregator/plugin.sh
tests/unit/review-aggregator-v2-test.sh
tests/unit/review-aggregator-test.sh
tests/unit/review-aggregator-roster-test.sh
docs/wiki/plugins/review-aggregator.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-040-composable-gate-lens-taxonomy.md
docs/adr/ADR-001-plugin-contract.md
tests/integration/review-lenses-output-test.sh
tests/integration/review-report-advisory-flow-test.sh
tests/integration/preflight-contract-templates-test.sh
tests/unit/contract-validator-input-gating-test.sh
scripts/lib/lint-contract.sh
config/templates/simple.yaml
tests/golden/parity/artifact-paths.golden
tests/golden/parity/state-shape.golden
tests/golden/parity/run-fixture.sh
```

```acceptance
SPEC-1[change]: manifest provides.result_contract == 2 (v2 contract declared)
SPEC-2[change]: manifest config.valid_verdicts lists complete and degraded (non-empty for the first time)
SPEC-3[change]: manifest outputs review_report_md declares required: true
SPEC-4[change]: success-path run writes result_contract:2 + verdict:complete + disposition:complete + non-empty reason into review-report.json
SPEC-5[change]: ZBUILD_STAGE_INPUTS lens_result array is the primary discovery path — when set, the glob is not consulted
SPEC-6[change]: review-report.md (summary) is written on the empty-lenses exit path (currently skipped when out_json is empty/unwritten)
SPEC-7[change]: SIGTERM/SIGINT trap writes verdict:degraded + disposition:interrupted + summary then re-raises (no trap exists at baseline)
SPEC-8[guard]: plugin always returns 0 (advisory never aborts — existing invariant)
SPEC-9[guard]: _ra_aggregate output matches _rr_aggregate byte-for-byte (equivalence preserved)
SPEC-10[guard]: roster discovery still collects declared group members when group env vars are set
WIRING: plugins/agent/review-aggregator/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/review-aggregator-v2-test.sh
SPEC-2: tests/unit/review-aggregator-v2-test.sh
SPEC-3: tests/unit/review-aggregator-v2-test.sh
SPEC-4: tests/unit/review-aggregator-v2-test.sh
SPEC-5: tests/unit/review-aggregator-v2-test.sh
SPEC-6: tests/unit/review-aggregator-v2-test.sh
SPEC-7: tests/unit/review-aggregator-v2-test.sh
SPEC-8: tests/unit/review-aggregator-test.sh
SPEC-9: tests/unit/review-aggregator-test.sh
SPEC-10: tests/unit/review-aggregator-roster-test.sh
```
