# Design: Migrate pr-delivery to Contract v2 (#1844)

## Architectural Decision Summary

**Goal.** Adopt result_contract:2 in the pr-delivery plugin: every terminal exit path writes `{result_contract:2, verdict, disposition, reason, data}` to pr-result.json; the manifest declares `result_contract:2`, `valid_verdicts:[pass,error]`, and three delivery events under `provides:`; rc is in {0,1}; gate_aggregator_result and review_report inputs are resolved via ZBUILD_STAGE_INPUTS; the dead hardcoded `review.json` guard is removed.

**Context.** pr-delivery is the final agent stage in the pipeline. Its manifest carries `valid_verdicts: []` and no `result_contract` key (defaults to v1). The plugin writes bare v1 JSON (status-keyed) on most paths and returns `rc=2` on the missing-state-file path — both violations of ADR-054 §4 (rc∈{0,1}) and ADR-055 §v2 (uniform result envelope). Issue #2250 wired the pr-open-blocked detection (plugin.sh lines 165-179) but never locked it with a v2 result assertion. Two input paths (`gate-aggregator-result.json`, `review-report.json`) are hardcoded artifact-dir strings rather than resolved via ZBUILD_STAGE_INPUTS. The `review.json` guard (lines 56-68) is dead code: the manifest comment at lines 34-39 records that the review input was dropped when stage:review was retired; review_report via ZBUILD_STAGE_INPUTS is the surviving review source.

**Decision.** Add `_pr_delivery_write_result` helper to plugin.sh; replace all v1 pr-result.json writes with v2 calls on every exit path; fix `return 2 → return 1` on the missing-state-file path; remove the dead review.json guard block; resolve `gate_aggregator_result` and `review_report` from ZBUILD_STAGE_INPUTS (with path fallback for non-engine invocations). Update manifest.yaml with `result_contract:2`, `valid_verdicts:[pass,error]`, and `events:[pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run]`. Write the unit test first (TDD), confirm it is red at merge-base, then implement. Update the integration test with additive v2 assertions on existing SPECs plus SPEC-10 for the pr-open-blocked integration path; update SPEC-4's fixture from review.json to review_report (ZBUILD_STAGE_INPUTS) since the old guard mechanism is removed.

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
```

```acceptance
SPEC-1[change]: manifest provides declares result_contract:2; config.valid_verdicts contains pass and error; provides.events includes pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run; role:pr and primary:true on pr_url are retained; hooks section has only run: (no cleanup:)
SPEC-2[change]: missing state_file argument → rc=1 (not rc=2) and pr-result.json written with result_contract:2, verdict=error, disposition=misconfigured
SPEC-3[change]: review_report (via ZBUILD_STAGE_INPUTS) signals block → rc=1, pr-result.json has result_contract:2, verdict=error, disposition=complete
SPEC-4[change]: dry-run path → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-5[change]: merge delegation success → rc=0, pr-result.json has result_contract:2, verdict=pass
SPEC-6[change]: merge delegation failure → rc=1, pr-result.json has result_contract:2, verdict=error
SPEC-7[change]: pr-open delegation success → rc=0, pr-result.json has result_contract:2, verdict=pass, disposition=complete
SPEC-8[change]: pr-open returns rc=0 with verdict=blocked → pr-delivery returns rc=1, pr-result.json has result_contract:2, verdict=error, disposition=complete, reason contains review_signal_missing (locks #2250 at v2 result level)
SPEC-9[change]: fallback gh-pr-create success → rc=0, pr-result.json has result_contract:2, verdict=pass
SPEC-10[change]: fallback gh-pr-create failure → rc=1, pr-result.json has result_contract:2, verdict=error, disposition=unavailable
SPEC-11[change]: plugin.sh contains no hardcoded gate-aggregator-result.json or review-report.json literal path strings — inputs resolved via ZBUILD_STAGE_INPUTS
SPEC-12[change]: plugin.sh contains no hardcoded review.json literal path string — dead input guard removed
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
```

```supersedes
tests/integration/pr-pipeline-test.sh [SPEC-4]: test presents review.json with verdict=block + ZBUILD_DRY_RUN=1 to trigger the old hardcoded guard (plugin.sh lines 56-68); after #1844 removes that guard entirely, the same fixture does not trigger any block path and the dry-run arm returns rc=0 — the test fixture must be updated to present review_report via ZBUILD_STAGE_INPUTS (or a fallback-resolved review-report.json) to preserve the block-guard behavior
```

LOOP_COMPLETE
