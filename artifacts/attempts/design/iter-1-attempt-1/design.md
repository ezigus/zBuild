# Design: Migrate merge, pr-open, deploy-release to contract v2 (issue #1849)

## Architectural decision summary

**Goal.** Bring three T0 tool plugins — `merge`, `pr-open` (id: `pr`), and `deploy-release` — to the ADR-054/ADR-055 v2 result contract: `result_contract:2` in `provides`, mandatory `verdict`/`disposition`/`reason` on every result write, `rc ∈ {0,1}`, `valid_verdicts` enumerated, `provides.role` and `provides.events` declared where permitted, and no hardcoded declared-input artifact paths in plugin code.

**Context.** These three plugins remain on v1 shapes (`schema_version:1`, freeform `status` field, `return 2` on error paths). They are the last batch in the F-wave migration (#1833–#1849). `core/contract/version.sh` declares `_ZBUILD_CONTRACT_MIN=1 _ZBUILD_CONTRACT_MAX=2`; after #1850 raises the floor all undeclared plugins are refused at load — migrating now is what makes that a one-line change.

Current manifest state by plugin:
- **merge**: no `provides:` block at all; `valid_verdicts: []` in config
- **pr-open**: has `provides:` with events but no role (manifest-comment constraint — must not gain a role); `valid_verdicts: []` in config
- **deploy-release**: has `provides:` with role and events already; `valid_verdicts: [deployed, error]` in config (already non-empty and correct for deploy-release's own exit paths); needs only `result_contract: 2` added to its existing `provides:` block

Per reference manifests (mutation-gate, teardown), `result_contract: 2` is a field inside the `provides:` section, not `config:`.

**Decision.** Migrate all three via TDD ordering per plugin: failing v2 tests first, then manifest, then plugin.sh, then update all existing tests that pin v1 fields or rc=2. Deploy-release and pr-open already have `provides:` sections; merge gains one. pr-open must NOT get a role (manifest comment constraint — retained).

For declared inputs (`gate_aggregator_result`, `review_report`, `pr_url`), replace hardcoded `$artifacts_dir/…` path constructions with `ZBUILD_STAGE_INPUTS` jq reads plus an `artifacts_dir` fallback, because `pr-delivery` sources `merge.sh` and `pr-open.sh` directly without engine dispatch (no `ZBUILD_STAGE_INPUTS` set in that call path).

**rc convention (v2).** Verdict-outcome paths (pass, blocked, error) return rc=0 — the verdict field is what drives blocking, not the exit code. Infrastructure failures (missing state_file argument, unresolvable ZBUILD_REPO_ROOT) return rc=1. No path returns rc=2. The blocked verdict (review verdict=block, no review signal) returns rc=0 and writes `verdict=blocked`; existing tests that assert `rc=2` on blocked paths (pr-open-test.sh, pr-pipeline-test.sh) must be updated to expect rc=0 with `verdict=blocked` in JSON.

**pr_fallback.** The pr_fallback merge outcome maps to `verdict=pass, data.mode=pr_fallback` — not a verdict value, not added to `valid_verdicts`.

**Router budgets.** All three are T0 tools with no LLM calls; all manifests already declare `tier_default: T0` with no `router:` block — the correct and complete budget declaration for LLM-free tools. No `router:` block is added.

**Primary outputs.** All three manifests already declare `primary: true` on their canonical result artifact. The merge manifest migration (adds `provides:`) must not displace that declaration.

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
SPEC-1[change]: merge manifest provides declares result_contract:2, role:merge_executor, events:[plugin.result]
SPEC-2[change]: merge/config valid_verdicts updated from [] to [pass,error]
SPEC-3[change]: merge-result.json carries result_contract:2, verdict=pass, disposition:complete, reason on squash-merge success path
SPEC-4[change]: merge-result.json carries result_contract:2, verdict=pass, data.mode=pr_fallback on gate-absent or gate-fail fallback paths
SPEC-5[change]: merge-result.json carries result_contract:2, verdict=error, disposition, reason on all error paths (branch-is-main, push failure, gh failure)
SPEC-6[change]: merge plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-7[change]: merge plugin reads gate_aggregator_result path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded path for this declared input)
SPEC-8[change]: pr-open manifest provides declares result_contract:2
SPEC-9[change]: pr-open/config valid_verdicts updated from [] to [pass,blocked,error]
SPEC-10[change]: pr-result.json carries result_contract:2, verdict=pass, disposition, reason on opened and updated paths
SPEC-11[change]: pr-result.json carries result_contract:2, verdict=blocked, disposition, reason when review verdict=block or no review signal (fail-closed); rc=0 not rc=2
SPEC-12[change]: pr-result.json carries result_contract:2, verdict=error, disposition, reason on error paths (branch-is-main, push failure, gh failure); rc=1 not rc=2
SPEC-13[change]: pr-open plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-14[change]: pr-open plugin reads review_report path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded path for this declared input)
SPEC-15[change]: deploy-release manifest provides declares result_contract:2 (valid_verdicts:[deployed,error] already correct and unchanged)
SPEC-16[change]: deploy-result.json carries result_contract:2, disposition, reason on every exit path (dry-run, tag success, tag failure, push failure, state_file-absent)
SPEC-17[change]: deploy-release plugin returns rc ∈ {0,1} on all exit paths — state_file-absent path returns rc=1 not rc=2
SPEC-18[change]: deploy-release plugin reads pr_url path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded path for this declared input)
SPEC-19[guard]: merge still routes to pr_open_run (pr-fallback) when gate verdict is not pass or gate artifact is absent
SPEC-20[guard]: pr-open still refuses (writes verdict=blocked, rc=0) when review.json verdict=block
SPEC-21[guard]: pr-open still halts before push and before gh pr create when branch has 0 commits ahead of merge-base
SPEC-22[guard]: pr-open advisory review section renders finding count and top bullets in the PR body
SPEC-23[guard]: deploy-result.json verdict=deployed and rc=0 on git tag+push success path
SPEC-24[guard]: all three manifests declare tier_default: T0 with no router: block — absence of router: is the correct budget declaration for LLM-free T0 tools
SPEC-25[guard]: all three manifests retain primary: true on their canonical result output (merge_result, pr_url, deploy_result) after the v2 migration

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
```

## Notes on scope expansion and refinements vs prior design

**Correction: deploy-release valid_verdicts.** The prior design stated "All three have `valid_verdicts: []`, which is incorrect." This was wrong for deploy-release: its manifest already carries `valid_verdicts: [deployed, error]`, which is correct for the paths deploy-release itself writes (dry-run writes `verdict:deployed`, tag/push failure writes `verdict:error`, success writes `verdict:deployed`). The `verdict:skipped` outcome is written by the deploy AGENT in its own skip path, not by deploy-release. The deploy-release manifest migration is therefore `result_contract:2` in `provides:` only — valid_verdicts is already correct and unchanged (hence SPEC-15 vs the prior design's SPEC-13 wording).

**Correction: result_contract placement.** `result_contract: 2` is a field within the `provides:` section, not `config:`. Confirmed by reference manifests (mutation-gate, teardown, coverage-gate). All three migration targets add it to `provides:`.

**SPEC split: rc convention clarification.** The prior design combined rc change and verdict shape into single SPECs. This design separates them so the acceptance gate can prove each is independently testable. The rc convention for v2 tool plugins: verdict outcomes (pass, blocked, error for non-infrastructure failures) return rc=0; infrastructure failures (missing state_file argument) return rc=1; no path returns rc=2. Blocked path (review block, no review signal) is a verdict outcome → rc=0.

**Test files requiring rc/field updates (all in scope above):**
- `plugins/tool/pr-open/tests/pr-open-test.sh`: three `assert_exit_code "..." "2"` assertions (blocked→rc=0, no-signal→rc=0, main-branch→rc=1); `.status` field reads become `.verdict`
- `tests/unit/pr-open-zero-commits-halts-test.sh`: `assert_eq "[SPEC-8] pr_open_run returns 2"` → rc=1 (0-commit is an infrastructure halt, not a blocked verdict)
- `tests/integration/pr-pipeline-test.sh`: SPEC-4 `[[ $_rc4 -ne 0 ]]` fails after blocked→rc=0; SPEC-9 `.draft` direct-field assertion moves to `.data.draft` in v2 shape
- `tests/integration/merge-policy-auto-test.sh`: `.status == "merged"` / `.status == "pr_fallback"` → `.verdict == "pass"` + `.data.mode`
- `tests/integration/merge-policy-auto-unless-flagged-test.sh`: `.status == "merged"` → `.verdict == "pass"`
- `plugins/agent/deploy/tests/deploy-test.sh` SPEC-7: `schema_version=1` on dry-run deploy-result.json → `result_contract=2`
- `tests/golden/pr-result-artifact.golden`: v1 shape `{"schema_version":1,"status":"opened",...}` → v2 shape
- `tests/unit/plugin-artifact-goldens-test.sh` G4: asserts `schema_version == 1` and `"status"` key → must update to `result_contract == 2` and `"verdict"` key

**Consuming agents included for awareness:**
- `plugins/agent/pr-delivery/plugin.sh`: sources merge.sh and pr-open.sh directly; `ZBUILD_STAGE_INPUTS` is not set in this call path, so the artifacts_dir fallback in input path resolution is specifically required for this call path
- `plugins/agent/deploy/plugin.sh`: calls `deploy_release_run`; writes some deploy-result.json paths in its own skip/guard paths with v1 shapes (out of scope — deploy agent migration is a separate issue)
