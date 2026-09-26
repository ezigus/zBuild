# Design: Migrate merge, pr-open, deploy-release to contract v2 (issue #1849)

## Architectural decision summary

**Goal.** Bring three T0 tool plugins — `merge`, `pr-open` (id: `pr`), and `deploy-release` — to the ADR-054/ADR-055 v2 result contract: `result_contract:2` in `provides`, mandatory `verdict`/`disposition`/`reason` on every result write, `rc ∈ {0,1}`, `valid_verdicts` enumerated, `provides.role` and `provides.events` declared where permitted, and no hardcoded declared-input artifact paths in plugin code.

**Context.** These three plugins remain on v1 shapes (`schema_version:1`, freeform `status` field, `return 2` on error paths). They are the last batch in the F-wave migration (#1833–#1849). `core/contract/version.sh` declares `_ZBUILD_CONTRACT_MIN=1 _ZBUILD_CONTRACT_MAX=2`; after #1850 raises the floor all undeclared plugins are refused at load — migrating now is what makes that a one-line change.

Current manifest state by plugin:
- **merge**: no `provides:` block at all; `valid_verdicts: []` in config; `hooks:` has only `run:`
- **pr-open**: has `provides:` with `events:` but no `role:` (manifest-comment constraint — must not gain a role); `valid_verdicts: []` in config; `hooks:` has only `run:`
- **deploy-release**: has `provides:` with `role:deploy_release_executor` and `events:` already; `valid_verdicts: [deployed, error]` already correct; `hooks:` has only `run:`

Per reference manifests (mutation-gate, teardown), `result_contract: 2` is a field inside the `provides:` section, not `config:`.

**Decision.** Migrate all three via TDD ordering per plugin: failing v2 tests first, then manifest, then plugin.sh, then update all existing tests that pin v1 fields or rc=2. Deploy-release and pr-open already have `provides:` sections; merge gains one. pr-open must NOT get a role (manifest comment constraint — retained).

For declared inputs (`gate_aggregator_result`, `review_report`, `pr_url`), replace hardcoded `$artifacts_dir/…` path constructions with `ZBUILD_STAGE_INPUTS` jq reads plus an `artifacts_dir` fallback, because `pr-delivery` sources `merge.sh` and `pr-open.sh` directly without engine dispatch (no `ZBUILD_STAGE_INPUTS` set in that call path).

**rc convention (v2).** Verdict-outcome paths (pass, blocked, error) return rc=0 — the verdict field is what drives blocking, not the exit code. Infrastructure failures (missing state_file argument, unresolvable ZBUILD_REPO_ROOT) return rc=1. No path returns rc=2. The blocked verdict (review verdict=block, no review signal) returns rc=0 and writes `verdict=blocked`; existing tests that assert `rc=2` on blocked paths (pr-open-test.sh, pr-pipeline-test.sh) must be updated to expect rc=0 with `verdict=blocked` in JSON.

**pr_fallback.** The pr_fallback merge outcome maps to `verdict=pass, data.mode=pr_fallback` — not a verdict value, not added to `valid_verdicts`.

**Router budgets.** All three are T0 tools with no LLM calls; all manifests already declare `tier_default: T0` with no `router:` block — the correct and complete budget declaration for LLM-free tools. No `router:` block is added.

**Primary outputs.** All three manifests already declare `primary: true` on their canonical result artifact. The merge manifest migration (adds `provides:`) must not displace that declaration.

**Cleanup hooks (#1829).** All three plugin.sh files implement an empty cleanup function body. Per ADR-056, when `hooks.cleanup` is absent from the manifest, the engine emits `plugin.cleanup.absent` and returns rc=0 — absence is the explicit recorded state, not an omission. None of the three manifests declare a `cleanup:` hook, and none should: there is nothing to free. This is the correct and recorded declaration.

**provides.events/role retained.** pr-open already declares `events:[plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work]` with no role (constraint preserved). deploy-release already declares `role:deploy_release_executor` and `events:[deploy.release.complete, deploy.release.dry_run, release.published, release.tagged]`. Adding `result_contract:2` to these `provides:` sections must not displace any existing key.

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
SPEC-8[change]: pr-open manifest provides declares result_contract:2 (existing events retained, no role added — constraint preserved)
SPEC-9[change]: pr-open/config valid_verdicts updated from [] to [pass,blocked,error]
SPEC-10[change]: pr-result.json carries result_contract:2, verdict=pass, disposition, reason on opened and updated paths
SPEC-11[change]: pr-result.json carries result_contract:2, verdict=blocked, disposition, reason when review verdict=block or no review signal (fail-closed); rc=0 not rc=2
SPEC-12[change]: pr-result.json carries result_contract:2, verdict=error, disposition, reason on error paths (branch-is-main, push failure, gh failure); rc=1 not rc=2
SPEC-13[change]: pr-open plugin returns rc ∈ {0,1} on all exit paths — no path returns rc=2
SPEC-14[change]: pr-open plugin reads review_report path via ZBUILD_STAGE_INPUTS with artifacts_dir fallback (no hardcoded path for this declared input)
SPEC-15[change]: deploy-release manifest provides declares result_contract:2 (existing role:deploy_release_executor and events retained; valid_verdicts:[deployed,error] already correct and unchanged)
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
SPEC-26[guard]: pr-open manifest provides retains events:[plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work] and has no role after result_contract:2 is added
SPEC-27[guard]: deploy-release manifest provides retains role:deploy_release_executor and events:[deploy.release.complete, deploy.release.dry_run, release.published, release.tagged] after result_contract:2 is added
SPEC-28[guard]: all three manifests declare no cleanup: hook (hooks section contains only run:) — empty cleanup function bodies in plugin.sh; manifest-absent cleanup is the correct recorded declaration per ADR-056 #1829; engine emits plugin.cleanup.absent rc=0

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
SPEC-26: tests/unit/pr-open-v2-result-test.sh
SPEC-27: tests/unit/deploy-release-v2-result-test.sh
SPEC-28: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
```

## Notes on scope and refinements

**Cleanup hook (#1829).** All three plugin.sh files have an empty cleanup function body (`merge_cleanup`, `pr_open_cleanup`, `deploy_release_cleanup`). Per ADR-056, when `hooks.cleanup` is absent from the manifest, the engine emits `plugin.cleanup.absent` and returns rc=0. None of the three migration target manifests declare a `cleanup:` hook — correct, because there is nothing to free. SPEC-28 guards that this absence is the declared state after the v2 migration.

**provides declarations guarded explicitly (SPEC-26, SPEC-27).** pr-open already carries `events:` in its `provides:` block. deploy-release already carries `role:` and `events:`. SPEC-8 and SPEC-15 assert only the new `result_contract:2` field (a `[change]`); SPEC-26 and SPEC-27 guard that the existing declarations survive the edit (a `[guard]` — these are not changes, so the negative-control is skipped by the acceptance gate).

**Correction: deploy-release valid_verdicts.** Already `[deployed, error]` — correct for the paths deploy-release itself writes. Unchanged by this migration (not in SPEC-15's scope of change).

**Correction: result_contract placement.** `result_contract: 2` belongs inside `provides:`, not `config:`. Confirmed by mutation-gate and teardown reference manifests.

**rc convention.** v2: all verdict outcomes return rc=0; infrastructure failures (missing state_file, unresolvable root) return rc=1; no path returns rc=2.

**Test files requiring updates (all in scope):**
- `plugins/tool/pr-open/tests/pr-open-test.sh`: `assert_exit_code "2"` × 3 → rc=0/1; `.status` → `.verdict`
- `tests/unit/pr-open-zero-commits-halts-test.sh`: rc=2 → rc=1 (0-commit is infrastructure halt)
- `tests/integration/pr-pipeline-test.sh`: blocked→rc=0; `.draft` → `.data.draft`
- `tests/integration/merge-policy-auto-test.sh`: `.status == "merged"` → `.verdict == "pass"` + `.data.mode`
- `tests/integration/merge-policy-auto-unless-flagged-test.sh`: `.status == "merged"` → `.verdict == "pass"`
- `plugins/agent/deploy/tests/deploy-test.sh`: `schema_version=1` → `result_contract=2`
- `tests/golden/pr-result-artifact.golden`: v1 shape → v2 shape
- `tests/unit/plugin-artifact-goldens-test.sh` G4: `schema_version == 1` + `"status"` → `result_contract == 2` + `"verdict"`

**pr-delivery fallback path.** `plugins/agent/pr-delivery/plugin.sh` sources merge.sh and pr-open.sh directly without lifecycle.sh dispatch — `ZBUILD_STAGE_INPUTS` is not set in this call path. The `artifacts_dir` fallback in SPEC-7/SPEC-14/SPEC-18 is specifically required to keep this call path working after the ZBUILD_STAGE_INPUTS read is added.
