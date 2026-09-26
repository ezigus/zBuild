# Design: Migrate merge, pr-open, deploy-release to contract v2 (issue #1849)

## Architectural decision summary

**Goal.** Bring three T0 tool plugins — `merge`, `pr-open` (id: `pr`), and `deploy-release` — to the ADR-054/ADR-055 v2 result contract: `result_contract:2` in `provides`, mandatory `verdict`/`disposition`/`reason` on every result write, `rc ∈ {0,1}`, `valid_verdicts` enumerated, `provides.role` and `provides.events` declared where permitted, and no hardcoded declared-input artifact paths in plugin code.

**Context.** These three plugins remain on v1 shapes (`schema_version:1`, freeform `status` field, `return 2` on error paths). They are the last batch in the F-wave migration (#1833–#1849). `core/contract/version.sh` declares `_ZBUILD_CONTRACT_MIN=1 _ZBUILD_CONTRACT_MAX=2`; after #1850 raises the floor all undeclared plugins are refused at load — migrating now is what makes that a one-line change. The merge manifest currently has no `provides:` block. All three have `valid_verdicts: []`, which is incorrect.

**Decision.** Migrate all three via TDD ordering per plugin: failing v2 tests first, then manifest, then plugin.sh, then update all existing tests that pin v1 fields or rc=2. Deploy-release and pr-open already have `provides:` sections; merge gains one. pr-open must NOT get a role (manifest comment constraint — retained). For declared inputs (`gate_aggregator_result`, `review_report`, `pr_url`), replace hardcoded `$artifacts_dir/…` path constructions with `ZBUILD_STAGE_INPUTS` jq reads plus an `artifacts_dir` fallback, because `pr-delivery` sources `merge.sh` and `pr-open.sh` directly without engine dispatch (no `ZBUILD_STAGE_INPUTS` set in that call path). pr_fallback maps to `verdict=pass, data.mode=pr_fallback` — not a verdict value, not added to `valid_verdicts`.

**verdict_classify extension.** pr-open declares `blocked` as a valid_verdict. `verdict_classify` in `core/pipeline/verdict.sh` has no `blocked` arm — it falls through to `*)` → unknown, which causes `lint-verdict-classify` SPEC-6 (every shipped manifest is compliant) and SPEC-10 (every declared verdict appears in ADR-019's table) to fail. `blocked` must be added to `verdict_classify` (→ warn: the PR was deliberately blocked by review decision, not an error in the plugin) and to ADR-019's verdict table. This is a structural prerequisite for the pr-open valid_verdicts change.

**RC migration for guard paths.** After v2 migration, the review-block path (pr-open), the 0-commit-branch path (pr-open), and the gate-fail fallback path (merge) all change their exit codes or result shape. These were previously tagged [guard] but the assertions test NEW behavior (v2 verdict=pass field, rc=0 not rc=2, rc=1 not rc=2) that does not exist at the merge-base — they are [change] SPECs.

**Router budgets.** All three are T0 tools with no LLM calls. `tier_default: T0` is the complete budget declaration. All three manifests already declare this — no `router:` block is added. **Primary outputs.** All three manifests already declare `primary: true` on their canonical result artifact. The merge manifest migration must not disturb that declaration.

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
docs/adr/ADR-019-review-fail-closed-on-test-failure.md
docs/wiki/plugins/merge.md
docs/wiki/plugins/pr.md
docs/wiki/plugins/deploy-release.md
core/contract/version.sh
core/pipeline/verdict.sh
core/plugin-registry/manifest-validation.sh
scripts/lib/lint-verdict-classify.sh
tests/unit/lint-verdict-classify-test.sh
plugins/agent/pr-delivery/plugin.sh
plugins/agent/deploy/plugin.sh
```

```acceptance
SPEC-1[change]: merge manifest provides declares result_contract:2, role:merge_executor, events:[plugin.result]
SPEC-2[change]: merge/config valid_verdicts updated from [] to [pass,error]
SPEC-3[change]: merge-result.json carries result_contract:2, verdict=pass, disposition:complete, reason on squash-merge success path
SPEC-4[change]: merge-result.json carries result_contract:2, verdict=pass, data.mode=pr_fallback on gate-absent or gate-fail fallback paths
SPEC-5[change]: merge-result.json carries result_contract:2, verdict=error, disposition, reason on all error paths (branch-is-main, push failure, gh failure)
SPEC-6[change]: merge plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-7[change]: merge plugin reads gate_aggregator_result path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded declared-input path)
SPEC-8[change]: pr-open manifest provides declares result_contract:2 (existing events retained, no role added — do-not-add constraint preserved)
SPEC-9[change]: pr-open/config valid_verdicts updated from [] to [pass,blocked,error]
SPEC-10[change]: pr-result.json carries result_contract:2, verdict=pass, disposition, reason on opened and updated paths
SPEC-11[change]: pr-result.json carries result_contract:2, verdict=blocked, disposition, reason when review verdict=block or no review signal (fail-closed)
SPEC-12[change]: pr-result.json carries result_contract:2, verdict=error, disposition, reason on error paths (branch-is-main, push failure, gh failure)
SPEC-13[change]: pr-open plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-14[change]: pr-open plugin reads review_report path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded declared-input path)
SPEC-15[change]: deploy-release manifest provides declares result_contract:2 (existing role:deploy_release_executor and events retained)
SPEC-16[change]: deploy-result.json carries result_contract:2, disposition, reason on every exit path (dry-run, tag success, tag failure, push failure, state_file-absent)
SPEC-17[change]: deploy-release plugin returns rc ∈ {0,1} on all exit paths — state_file-absent path returns rc=1 not rc=2
SPEC-18[change]: deploy-release plugin reads pr_url path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded declared-input path)
SPEC-19[change]: merge gate-fail and gate-absent fallback paths write result_contract:2, verdict=pass, data.mode=pr_fallback (v2 verdict field absent at merge-base)
SPEC-20[change]: pr-open returns rc=0 (not rc=2) when review.json verdict=block — writes verdict=blocked (exit code migrated to v2 contract)
SPEC-21[change]: pr-open returns rc=1 (not rc=2) when branch has 0 commits ahead of merge-base (exit code migrated from v1 rc=2 to v2 rc=1)
SPEC-22[guard]: pr-open advisory review section renders finding count and top bullets in the PR body
SPEC-23[guard]: deploy-result.json verdict=deployed and rc=0 on git tag+push success path
SPEC-24[guard]: all three manifests declare tier_default: T0 with no router: block — absence of router: is the correct budget declaration for LLM-free T0 tools
SPEC-25[guard]: all three manifests retain primary: true on their canonical result output (merge_result, pr_url, deploy_result) after the v2 migration
SPEC-26[guard]: pr-open manifest provides retains events:[plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work] and no role: key (do-not-add constraint preserved)
SPEC-27[guard]: deploy-release manifest provides retains role:deploy_release_executor and events:[deploy.release.complete, plugin.result.written, deploy.release.skipped, deploy.release.tag_pushed]
SPEC-28[guard]: all three manifests declare no cleanup: hook (hooks section contains only run:)
SPEC-29[change]: verdict_classify maps verdict 'blocked' to warn (not unknown); ADR-019 verdict table updated to include blocked row — prerequisite for lint-verdict-classify SPEC-6/SPEC-10 to pass with pr-open's valid_verdicts

WIRING:
plugins/tool/merge/manifest.yaml
plugins/tool/pr-open/manifest.yaml
plugins/tool/deploy-release/manifest.yaml
core/pipeline/verdict.sh

TESTFILES:
SPEC-1: tests/unit/merge-v2-result-test.sh
SPEC-2: tests/unit/merge-v2-result-test.sh
SPEC-3: tests/unit/merge-v2-result-test.sh
SPEC-4: tests/unit/merge-v2-result-test.sh
SPEC-5: tests/unit/merge-v2-result-test.sh
SPEC-6: tests/unit/merge-v2-result-test.sh
SPEC-7: tests/unit/merge-v2-result-test.sh
SPEC-8: tests/unit/pr-open-v2-result-test.sh
SPEC-9: tests/unit/pr-open-v2-result-test.sh
SPEC-10: tests/unit/pr-open-v2-result-test.sh
SPEC-11: tests/unit/pr-open-v2-result-test.sh
SPEC-12: tests/unit/pr-open-v2-result-test.sh
SPEC-13: tests/unit/pr-open-v2-result-test.sh
SPEC-14: tests/unit/pr-open-v2-result-test.sh
SPEC-15: tests/unit/deploy-release-v2-result-test.sh
SPEC-16: tests/unit/deploy-release-v2-result-test.sh
SPEC-17: tests/unit/deploy-release-v2-result-test.sh
SPEC-18: tests/unit/deploy-release-v2-result-test.sh
SPEC-19: tests/integration/merge-policy-auto-test.sh
SPEC-20: tests/integration/pr-pipeline-test.sh
SPEC-21: tests/unit/pr-open-zero-commits-halts-test.sh
SPEC-22: tests/unit/pr-open-advisory-review-test.sh
SPEC-23: tests/unit/deploy-release-v2-result-test.sh
SPEC-24: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-25: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-26: tests/unit/pr-open-v2-result-test.sh
SPEC-27: tests/unit/deploy-release-v2-result-test.sh
SPEC-28: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-29: tests/unit/lint-verdict-classify-test.sh
```

## Notes on scope expansion beyond the plan seed

**New test files added to scope:**
- `plugins/tool/pr-open/tests/pr-open-test.sh` — asserts `.status == "blocked/opened/error"` on pr-result.json (v1 field, breaks after SPEC-10–12)
- `plugins/agent/deploy/tests/deploy-test.sh` — asserts `schema_version=1` and `verdict=deployed/skipped/error` on deploy-result.json written by deploy-release
- `tests/integration/deployed-template-e2e-test.sh` — asserts `verdict=deployed` on deploy-result.json (guard behavior, must pass after migration)
- `tests/golden/pr-result-artifact.golden` — encodes `{"schema_version":1,"status":"opened",...}`; must be updated to v2 shape
- `tests/unit/plugin-artifact-goldens-test.sh` — asserts `schema_version == 1` and exact golden match against pr-result-artifact.golden; both assertions must be updated
- `tests/unit/lint-verdict-classify-test.sh` — SPEC-6 [guard] and SPEC-10 fail because `blocked` is now declared in pr-open's valid_verdicts but absent from `verdict_classify` and ADR-019's table

**Core files added to scope:**
- `core/pipeline/verdict.sh` — `verdict_classify` function needs a `blocked` → `warn` arm; without it, every shipped-tree lint run fails on pr-open's manifest
- `docs/adr/ADR-019-review-fail-closed-on-test-failure.md` — contains the verdict classification table that `lint-verdict-classify-test.sh` SPEC-10 and SPEC-13 validate; `blocked` must be added as a warn row

**Classification rationale for `blocked`.** The `blocked` verdict means pr-open deliberately refused to open a PR because a review blocked it (rc=0, intentional stop). This is semantically parallel to `request_changes` (review found issues → warn indicator, not fail). Classifying it `warn` keeps the indicator at ⚠ YELLOW — the pipeline is paused pending resolution, not defective. Since rc=0, `runner_read_stage_verdict` does not override to `fail`; the classification governs the indicator only.

**Integration tests with v1 field assertions that need updating:**
- `tests/integration/merge-policy-auto-test.sh` — asserts `.status == "merged"` and `.status == "pr_fallback"` on merge-result.json; also contains the SPEC-19 [change] assertion that the fallback path writes verdict=pass (v2 shape)
- `tests/integration/merge-policy-auto-unless-flagged-test.sh` — asserts `.status == "merged"` on merge-result.json
- `tests/integration/pr-pipeline-test.sh` — asserts `.draft` on pr-result.json (v1 field, moves under data:); also contains the SPEC-20 [change] assertion that rc=0 on block

**SPEC-19/20/21 re-tagged from [guard] to [change].** The prior design tagged these as guards because the underlying behaviors (route to fallback, refuse on block, halt on 0 commits) exist at the merge-base. But the assertions test the NEW v2 contract shape:
- SPEC-19 asserts `verdict==pass` field on the fallback result — absent at merge-base (v1 result has no verdict field)
- SPEC-20 asserts `rc=0` on the block path — at merge-base rc=2
- SPEC-21 asserts `rc=1` on the 0-commit path — at merge-base rc=2
All three correctly fail at baseline and must be tagged [change].

**Consuming agents included for awareness:**
- `plugins/agent/pr-delivery/plugin.sh` — sources merge.sh and pr-open.sh directly; the `artifacts_dir` fallback in ZBUILD_STAGE_INPUTS reads is specifically for this call path
- `plugins/agent/deploy/plugin.sh` — calls `deploy_release_run`; writes some deploy-result.json paths directly with v1 shapes on guard paths out of this issue's scope

**SPEC-29 negative control.** At merge-base, `verdict_classify "blocked"` returns `"unknown"` (falls to `*)`). The assertion `assert_eq "[SPEC-29] verdict_classify(blocked) is warn" "warn" "$(verdict_classify "blocked")"` fails at baseline (unknown ≠ warn) and passes at HEAD (warn = warn). The test-author adds this assertion to `tests/unit/lint-verdict-classify-test.sh`.

**SPEC-22/23/24/25/26/27/28 guard rationale.** All hold at the merge-base by definition (declared events, roles, tier_default, primary flag, no cleanup hook). They guard that the migration does not inadvertently remove or corrupt these pre-existing declarations.

LOOP_COMPLETE
