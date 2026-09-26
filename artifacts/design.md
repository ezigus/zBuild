# Design: Migrate merge, pr-open, deploy-release to contract v2 (issue #1849)

## Architectural decision summary

**Goal.** Bring three T0 tool plugins — `merge`, `pr-open` (id: `pr`), and `deploy-release` — to the ADR-054/ADR-055 v2 result contract: `result_contract:2` in `provides`, mandatory `verdict`/`disposition`/`reason` on every result write, `rc ∈ {0,1}`, `valid_verdicts` enumerated, `provides.role` and `provides.events` declared where permitted, and no hardcoded declared-input artifact paths in plugin code.

**Context.** These three plugins remain on v1 shapes (`schema_version:1`, freeform `status` field, `return 2` on error paths). They are the last batch in the F-wave migration (#1833–#1849). `core/contract/version.sh` declares `_ZBUILD_CONTRACT_MIN=1 _ZBUILD_CONTRACT_MAX=2`; after #1850 raises the floor all undeclared plugins are refused at load — migrating now is what makes that a one-line change. The merge manifest currently has no `provides:` block. All three have `valid_verdicts: []`, which is incorrect.

**Decision.** Migrate all three via TDD ordering per plugin: failing v2 tests first, then manifest, then plugin.sh, then update all existing tests that pin v1 fields or rc=2. Deploy-release and pr-open already have `provides:` sections; merge gains one. pr-open must NOT get a role (manifest comment constraint — retained). For declared inputs (`gate_aggregator_result`, `review_report`, `pr_url`), replace hardcoded `$artifacts_dir/…` path constructions with `ZBUILD_STAGE_INPUTS` jq reads plus an `artifacts_dir` fallback, because `pr-delivery` sources `merge.sh` and `pr-open.sh` directly without engine dispatch (no `ZBUILD_STAGE_INPUTS` set in that call path). pr_fallback maps to `verdict=pass, data.mode=pr_fallback` — not a verdict value, not added to `valid_verdicts`.

```scope
plugins/tool/merge/manifest.yaml
plugins/tool/merge/plugin.sh
plugins/tool/pr-open/manifest.yaml
plugins/tool/pr-open/plugin.sh
plugins/tool/deploy-release/manifest.yaml
plugins/tool/deploy-release/plugin.sh
tests/unit/merge-v2-result-test.sh
tests/unit/pr-open-v2-result-test.sh
tests/unit/deploy-release-v2-result-test.sh
tests/unit/pr-open-advisory-review-test.sh
tests/unit/pr-open-zero-commits-halts-test.sh
tests/unit/template-merge-policy-test.sh
plugins/tool/pr-open/tests/pr-open-test.sh
tests/integration/merge-policy-auto-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/integration/pr-pipeline-test.sh
plugins/agent/deploy/tests/deploy-test.sh
tests/integration/deployed-template-e2e-test.sh
tests/golden/pr-result-artifact.golden
tests/unit/plugin-artifact-goldens-test.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/merge.md
docs/wiki/plugins/pr.md
docs/wiki/plugins/deploy-release.md
core/contract/version.sh
core/plugin-registry/manifest-validation.sh
scripts/lib/lint-verdict-classify.sh
plugins/agent/pr-delivery/plugin.sh
plugins/agent/deploy/plugin.sh
```

```acceptance
SPEC-1[change]: merge manifest provides declares result_contract:2, role:merge_executor, valid_verdicts:[pass,error], events:[plugin.result]
SPEC-2[change]: merge-result.json carries result_contract:2, verdict=pass, disposition:complete, reason on squash-merge success path
SPEC-3[change]: merge-result.json carries result_contract:2, verdict=pass, data.mode=pr_fallback on gate-absent or gate-fail fallback paths
SPEC-4[change]: merge-result.json carries result_contract:2, verdict=error, disposition, reason on all error paths (branch-is-main, push failure, gh failure)
SPEC-5[change]: merge plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-6[change]: merge plugin reads gate_aggregator_result path via ZBUILD_STAGE_INPUTS (no hardcoded artifacts_dir path for this declared input)
SPEC-7[change]: pr-open manifest provides declares result_contract:2 and valid_verdicts:[pass,blocked,error]
SPEC-8[change]: pr-result.json carries result_contract:2, verdict=pass, disposition, reason on opened and updated paths
SPEC-9[change]: pr-result.json carries result_contract:2, verdict=blocked, disposition, reason when review verdict=block or no review signal (fail-closed)
SPEC-10[change]: pr-result.json carries result_contract:2, verdict=error, disposition, reason on error paths (branch-is-main, push failure, gh failure)
SPEC-11[change]: pr-open plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-12[change]: pr-open plugin reads review_report path via ZBUILD_STAGE_INPUTS (no hardcoded artifacts_dir path for this declared input)
SPEC-13[change]: deploy-release manifest provides declares result_contract:2
SPEC-14[change]: deploy-result.json carries result_contract:2, disposition, reason on every exit path (dry-run, tag success, tag failure, push failure, state_file-absent)
SPEC-15[change]: deploy-release plugin returns rc ∈ {0,1} on all exit paths — state_file-absent path returns rc=1 not rc=2
SPEC-16[change]: deploy-release plugin reads pr_url path via ZBUILD_STAGE_INPUTS (no hardcoded artifacts_dir path for this declared input)
SPEC-17[guard]: merge still routes to pr_open_run (pr-fallback) when gate verdict is not pass or gate artifact is absent
SPEC-18[guard]: pr-open still refuses (writes blocked result, rc=0 after change) when review.json verdict=block
SPEC-19[guard]: pr-open still halts before push and before gh pr create when branch has 0 commits ahead of merge-base
SPEC-20[guard]: pr-open advisory review section renders finding count and top bullets in the PR body
SPEC-21[guard]: deploy-result.json verdict=deployed and rc=0 on git tag+push success path

WIRING:
plugins/tool/merge/manifest.yaml
plugins/tool/pr-open/manifest.yaml
plugins/tool/deploy-release/manifest.yaml

TESTFILES:
SPEC-1: tests/unit/merge-v2-result-test.sh
SPEC-2: tests/unit/merge-v2-result-test.sh
SPEC-3: tests/unit/merge-v2-result-test.sh
SPEC-4: tests/unit/merge-v2-result-test.sh
SPEC-5: tests/unit/merge-v2-result-test.sh
SPEC-6: tests/unit/merge-v2-result-test.sh
SPEC-7: tests/unit/pr-open-v2-result-test.sh
SPEC-8: tests/unit/pr-open-v2-result-test.sh
SPEC-9: tests/unit/pr-open-v2-result-test.sh
SPEC-10: tests/unit/pr-open-v2-result-test.sh
SPEC-11: tests/unit/pr-open-v2-result-test.sh
SPEC-12: tests/unit/pr-open-v2-result-test.sh
SPEC-13: tests/unit/deploy-release-v2-result-test.sh
SPEC-14: tests/unit/deploy-release-v2-result-test.sh
SPEC-15: tests/unit/deploy-release-v2-result-test.sh
SPEC-16: tests/unit/deploy-release-v2-result-test.sh
SPEC-17: tests/integration/merge-policy-auto-test.sh
SPEC-18: tests/integration/pr-pipeline-test.sh
SPEC-19: tests/unit/pr-open-zero-commits-halts-test.sh
SPEC-20: tests/unit/pr-open-advisory-review-test.sh
SPEC-21: tests/unit/deploy-release-v2-result-test.sh
```

## Notes on scope expansion beyond the plan seed

**New test files added to scope:**
- `plugins/tool/pr-open/tests/pr-open-test.sh` — asserts `.status == "blocked/opened/error"` on pr-result.json (v1 field, breaks after SPEC-8–10)
- `plugins/agent/deploy/tests/deploy-test.sh` — asserts `schema_version=1` (SPEC-7 in that file) and `verdict=deployed/skipped/error` on deploy-result.json written by deploy-release
- `tests/integration/deployed-template-e2e-test.sh` — asserts `verdict=deployed` on deploy-result.json (guard behavior, must pass after migration)
- `tests/golden/pr-result-artifact.golden` — encodes `{"schema_version":1,"status":"opened",...}`; must be updated to v2 shape
- `tests/unit/plugin-artifact-goldens-test.sh` G4 — asserts `schema_version == 1` and exact golden match against pr-result-artifact.golden; both assertions must be updated

**Integration tests with v1 field assertions that need updating:**
- `tests/integration/merge-policy-auto-test.sh` — asserts `.status == "merged"` and `.status == "pr_fallback"` on merge-result.json (multiple SPEC)
- `tests/integration/merge-policy-auto-unless-flagged-test.sh` — asserts `.status == "merged"` on merge-result.json
- `tests/integration/pr-pipeline-test.sh` — asserts `.draft` on pr-result.json (v1 field, moves under data:)

**Consuming agents included for awareness (not implementation targets unless their own result shapes need updating):**
- `plugins/agent/pr-delivery/plugin.sh` — sources merge.sh and pr-open.sh directly; the artifacts_dir fallback exists specifically for this call path
- `plugins/agent/deploy/plugin.sh` — calls `deploy_release_run`; writes some deploy-result.json paths directly with v1 shapes on guard paths (gate-missing, gate-fail) that are not in this issue's scope

**pr-open SPEC-18 rc clarification.** After v2 migration, review-block and no-signal paths return rc=0 (not rc=2) but write `verdict=blocked`. The existing `pr-open-test.sh` and `pr-pipeline-test.sh` assertions that expect rc=2 on block must be updated to expect rc=0 with `verdict=blocked` in the result file.

LOOP_COMPLETE
