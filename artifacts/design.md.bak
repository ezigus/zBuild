# Design: Migrate pr-delivery to Contract v2 (#1844)

## Architectural Decision Summary

**Goal.** Adopt result_contract:2 in the pr-delivery plugin: every terminal exit path writes `{result_contract:2, verdict, disposition, reason, data}` to pr-result.json; the manifest declares `result_contract:2`, `valid_verdicts:[pass,error]`, and three delivery events under `provides:`; rc is in {0,1}; gate_aggregator_result and review_report inputs are resolved via ZBUILD_STAGE_INPUTS; the dead hardcoded `review.json` guard is removed; a SIGTERM/SIGINT trap via `stage_signal_begin` writes an interrupted result.

**Context.** pr-delivery is the final agent stage. Its manifest carries `valid_verdicts:[]` and no `result_contract` key (v1 default). The plugin writes bare v1 JSON on most paths and returns `rc=2` on the missing-state-file path — both violations of ADR-054 §4 (rc∈{0,1}) and ADR-055 §v2 (uniform result envelope). Issue #2250 wired pr-open-blocked detection (plugin.sh lines 165-179) but never locked it with a v2 result assertion. Two input paths (`gate-aggregator-result.json`, `review-report.json`) are hardcoded artifact-dir strings. The `review.json` guard (lines 56-68) is dead code. The plugin has no `stage_signal_begin` guard, so a mid-execution SIGTERM/SIGINT leaves no result file (analogous to intake before #1837; other v2 agent plugins — intake, plan, review-aggregator, deploy — all install a signal handler). The manifest has no comment recording the intentional absence of a `router:` block (pr-delivery is kind:agent but makes no direct LLM calls; `plugins/tool/pr-open/manifest.yaml` lines 17-21 and `plugins/tool/merge/manifest.yaml` lines 15-16 document this pattern for tool plugins).

**Decision.** Add `_pr_delivery_write_result` helper; replace all v1 pr-result.json writes with v2 calls on every exit path; fix `return 2 → return 1`; remove the dead review.json guard; resolve `gate_aggregator_result` and `review_report` from ZBUILD_STAGE_INPUTS with path fallback; source `scripts/lib/stage-signal.sh` and add `stage_signal_begin _pr_delivery_on_signal` / `stage_signal_end` guard around the delegation work so SIGTERM/SIGINT writes verdict=error/disposition=interrupted. Update manifest with `result_contract:2`, `valid_verdicts:[pass,error]`, events list, and a comment recording the router-absent rationale (analogous to pr-open/merge manifests). Write the unit test first (TDD), confirm red at merge-base, then implement. Extend the integration test with additive v2 assertions and bind the passing-run result shape to `tests/golden/pr-result-artifact.golden` via SPEC-16.

```scope
plugins/agent/pr-delivery/manifest.yaml
plugins/agent/pr-delivery/plugin.sh
tests/unit/pr-delivery-v2-result-test.sh
tests/integration/pr-pipeline-test.sh
tests/unit/pr-delivery-blocked-test.sh
tests/integration/merge-policy-auto-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/golden/pr-result-artifact.golden
tests/unit/plugin-artifact-goldens-test.sh
docs/wiki/plugins/pr-delivery.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-013-canonical-stage-list.md
core/pipeline/verdict.sh
core/plugin-registry/manifest-validation.sh
core/plugin-registry/manifest-index.sh
config/templates/simple.yaml
scripts/lib/stage-signal.sh
```

```acceptance
SPEC-1[change]: manifest provides declares result_contract:2; config.valid_verdicts contains pass and error; provides.events includes pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run; role:pr and primary:true on pr_url are retained; hooks section has only run: (no cleanup:)
SPEC-2[change]: missing state_file argument → rc=1 (not rc=2) and pr-result.json written with result_contract:2, verdict=error, disposition=misconfigured
SPEC-3[change]: review_report (via ZBUILD_STAGE_INPUTS) signals block → rc=1, pr-result.json has result_contract:2, verdict=error, disposition=complete
SPEC-4[change]: dry-run path → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-5[change]: merge delegation success → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-6[change]: merge delegation failure → rc=1, pr-result.json has result_contract:2, verdict=error, disposition=unavailable (fallback when delegate writes no result file)
SPEC-7[change]: pr-open delegation success → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-8[change]: pr-open returns rc=0 with verdict=blocked → pr-delivery returns rc=1, pr-result.json has result_contract:2, verdict=error, disposition=complete, reason contains review_signal_missing (locks #2250 at v2 result level)
SPEC-9[change]: fallback gh-pr-create success → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-10[change]: fallback gh-pr-create failure → rc=1, pr-result.json has result_contract:2, verdict=error, disposition=unavailable
SPEC-11[change]: plugin.sh contains no hardcoded gate-aggregator-result.json or review-report.json literal path strings — inputs resolved via ZBUILD_STAGE_INPUTS
SPEC-12[change]: plugin.sh contains no hardcoded review.json literal path string — dead input guard removed
SPEC-13[change]: manifest config: section contains a comment recording the intentional absence of a router: block (pr-delivery makes no direct model calls; analogous to pr-open/manifest.yaml lines 17-21 and merge/manifest.yaml lines 15-16)
SPEC-14[change]: plugin.sh installs a stage_signal_begin trap (_pr_delivery_on_signal); when a SIGTERM/SIGINT fires during delegation, pr-result.json is written with result_contract:2, verdict=error, disposition=interrupted, and the run function exits rc=1
SPEC-15[guard]: manifest inputs: every entry contains only id: and required: fields — no path:, type:, source:, or stage: fields — conformant with ADR-055 §1
SPEC-16[change]: passing pr-open delegation produces pr-result.json whose result_contract equals 2, verdict equals pass, disposition equals complete, data.pr_url is non-empty, and data.draft equals false — matching the structure of tests/golden/pr-result-artifact.golden
WIRING: plugins/agent/pr-delivery/plugin.sh
TESTFILES:
SPEC-1: tests/unit/pr-delivery-v2-result-test.sh
SPEC-2: tests/unit/pr-delivery-v2-result-test.sh
SPEC-3: tests/unit/pr-delivery-v2-result-test.sh
SPEC-4: tests/unit/pr-delivery-v2-result-test.sh
SPEC-5: tests/unit/pr-delivery-v2-result-test.sh
SPEC-6: tests/unit/pr-delivery-v2-result-test.sh
SPEC-7: tests/unit/pr-delivery-v2-result-test.sh
SPEC-8: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-9: tests/unit/pr-delivery-v2-result-test.sh
SPEC-10: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-11: tests/unit/pr-delivery-v2-result-test.sh
SPEC-12: tests/unit/pr-delivery-v2-result-test.sh
SPEC-13: tests/unit/pr-delivery-v2-result-test.sh
SPEC-14: tests/unit/pr-delivery-v2-result-test.sh
SPEC-15: tests/unit/pr-delivery-v2-result-test.sh
SPEC-16: tests/integration/pr-pipeline-test.sh tests/unit/plugin-artifact-goldens-test.sh
```

```supersedes
tests/integration/pr-pipeline-test.sh [SPEC-4]: test presents review.json with verdict=block + ZBUILD_DRY_RUN=1 to trigger the old hardcoded guard (plugin.sh lines 56-68); after #1844 removes that guard entirely, the same fixture does not trigger any block path and the dry-run arm returns rc=0 — the test fixture must be updated to present review_report via ZBUILD_STAGE_INPUTS (or a fallback-resolved review-report.json) to preserve the block-guard behavior
```

LOOP_COMPLETE
