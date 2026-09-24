# Design: Migrate merge, pr-open, deploy-release to contract v2

## Architectural Decision Summary

**Goal.** Promote three T0 tool plugins — `plugins/tool/merge`, `plugins/tool/pr-open`, and
`plugins/tool/deploy-release` — from the informal v1 result convention to the ADR-054 / ADR-055
contract v2: `result_contract:2` in each manifest's `provides:` block; every exit path writes
`verdict`, `disposition`, and `reason`; exit codes narrowed to `{0,1}`; declared inputs read
from `ZBUILD_STAGE_INPUTS` rather than hardcoded `$artifacts_dir/<name>` path constructions;
and signal-interrupted paths write `disposition=unavailable` rather than guessing the outcome.

**Context.** This is issue #1849, the final PR in the 17-issue F-wave migration series
(ADR-055 §1). Existing v2-migrated T0 peers — `mutation-gate`, `lint-gate`, `shape-floor`,
`teardown` — establish the reference pattern. The three plugins are internally dispatched
(pr-delivery sources merge and pr-open; deploy agent sources deploy-release) so `plugin_hook_call`
never fires, but `provides.result_contract:2` still gates the engine's result-reading behaviour.

Manifest state before migration:
- merge: no `provides:` block; `valid_verdicts: []` (empty) in config; no events declared;
  plugin.sh has `return 2` on six paths and no interruption handling.
- pr-open: has `provides.events` (two events); `valid_verdicts: []` (empty) in config; no role
  (explicitly prohibited by manifest comment); plugin.sh has `return 2` on ~14 paths, no
  interruption handling.
- deploy-release: has `provides.role` and `provides.events`; `valid_verdicts: [deployed,error]`
  in config (already correct, guard only); plugin.sh has `return 2` only on missing-state-file,
  no interruption handling.

Non-obvious side-effect: adding `blocked` to pr-open's `valid_verdicts` requires adding it to
`core/pipeline/verdict.sh`'s `verdict_classify` case arm; without this,
`scripts/lib/lint-verdict-classify.sh` fails the CI Lint job.

**Decision.** For each plugin:
1. Add `result_contract:2` to `provides:` in manifest. Merge also gains `role: merge_executor`
   and `provides.events: [plugin.result]` (both absent today). pr-open and deploy-release retain
   their existing `provides.events` declarations unchanged.
2. Every `jq` result write gains `result_contract:2`, `verdict`, `disposition`, and `reason`;
   plugin-specific payload fields move under `data:`.
3. All `return 2` sites become `return 1`.
4. Declared inputs resolved via `ZBUILD_STAGE_INPUTS` lookup with `$artifacts_dir` fallback.
5. Interruption handling: after each outward-facing call (gh squash-merge, gh pr create/edit,
   git push), capture the exit code. Signal-death rc (130/143/124) where the action's outcome
   is genuinely unknown → write `disposition=unavailable, verdict=error` before returning rc=1.
   Signal-death where the action definitely did not execute → `disposition=interrupted`. Other
   non-zero failures → `disposition=broken`. This folds in the "unavailable" requirement from
   ADR-054 §6: the plugin reports `unavailable` rather than guessing the outcome.
6. `review.json` (merge) and `review-report.json`/`review.json` (pr-open) BY-PATH reads remain
   as-is (documented non-declared inputs, out of scope for the paths-in-code rule).

Router budgets: all three plugins are T0 (no LLM calls). Established v2 T0 peers (mutation-gate,
lint-gate, shape-floor, teardown) carry no `router:` block. T0 satisfies the router-budget
requirement by absence; no `router:` block is added.

Cleanup hooks: all three plugins have empty cleanup stubs in plugin.sh but no `cleanup:` key in
`hooks:`. T0 tools have no LLM state to clean; deliberate absence is correct and unchanged.

`primary: true` output: already declared on all three manifests (`merge_result`, `pr_url`,
`deploy_result` respectively) — guard only.

TDD order per plugin: write v2 result test (including interruption paths) → confirm red →
implement → confirm green.

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
core/pipeline/verdict.sh
scripts/lib/lint-verdict-classify.sh
tests/unit/pr-open-advisory-review-test.sh
tests/unit/pr-open-zero-commits-halts-test.sh
tests/unit/template-merge-policy-test.sh
plugins/tool/pr-open/tests/pr-open-test.sh
plugins/agent/deploy/tests/deploy-test.sh
tests/integration/merge-policy-auto-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
tests/integration/pr-pipeline-test.sh
tests/unit/plugin-artifact-goldens-test.sh
tests/golden/pr-result-artifact.golden
tests/unit/lint-verdict-classify-test.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
docs/wiki/plugins/merge.md
docs/wiki/plugins/pr.md
docs/wiki/plugins/deploy-release.md
```

**Scope reasoning beyond seed.**

`core/pipeline/verdict.sh` + `scripts/lib/lint-verdict-classify.sh` — pr-open adds `blocked` to
its `valid_verdicts`. `lint-verdict-classify.sh` (wired into CI Lint) fails when a declared
verdict is absent from `verdict_classify`. `blocked` must be added to the case arm in verdict.sh.

`tests/unit/lint-verdict-classify-test.sh` — SPEC-4's test runs lint-verdict-classify over all
plugins; adding `blocked` to pr-open's manifest without the verdict.sh change causes a failure.

`plugins/tool/pr-open/tests/pr-open-test.sh` — asserts `"schema_version": 1` and `.status` at
top level; after v2 `status` moves to `data.status` and `result_contract:2` is added.

`plugins/agent/deploy/tests/deploy-test.sh` — asserts `schema_version=1` on the dry-run
path. The dry-run path in `deploy_release_run` writes `result_contract:2` after migration;
the assertion fails. In scope to update to check `result_contract=2`.

`tests/integration/merge-policy-auto-test.sh` and `merge-policy-auto-unless-flagged-test.sh` —
assert `jq -r '.status // empty'` on `merge-result.json`; after v2, `.status` lives under `data`.

`tests/integration/pr-pipeline-test.sh` — asserts `rc=2` from `pr_open_run` and reads `.draft`
directly; rc=2→1 breaks rc assertion; `.draft` moves to `data.draft`.

`tests/unit/pr-open-zero-commits-halts-test.sh` — asserts `rc=2`; rc=2→1 breaks the assertion.

`tests/unit/pr-open-advisory-review-test.sh` — asserts `.status == "opened"`; moves to `data.status`.

`tests/unit/plugin-artifact-goldens-test.sh` G4 + `tests/golden/pr-result-artifact.golden` —
G4 checks `schema_version == 1` and exact-matches the golden encoding `"status":"opened"` at
top level; both need updating to v2 shape.

`docs/adr/ADR-054-stage-contract.md` / `ADR-055-inter-stage-data-contract-v2.md` — authoritative
specification references for the contract being implemented. Wiki pages describe the plugin
contracts; a reviewer confirming behaviour against the wiki must see whether the wiki is accurate.

```acceptance
SPEC-1[change]: merge manifest declares provides.result_contract==2, config.valid_verdicts is updated to [pass,error] (was []), and provides.role==merge_executor
SPEC-2[change]: merge-result.json carries result_contract:2, verdict, disposition, and non-empty reason on every exit path (merged, pr_fallback, branch_is_main, push_failed, gh_create_failed, gh_merge_failed, interrupted with signal-death rc)
SPEC-3[change]: merge_run returns rc∈{0,1} on every exit path; no return 2
SPEC-4[change]: pr-open manifest declares provides.result_contract==2 and config.valid_verdicts is updated to [pass,blocked,error] (was []); verdict_classify('blocked') returns 'fail' (not 'unknown')
SPEC-5[change]: pr-result.json carries result_contract:2, verdict, disposition, and non-empty reason on every exit path (opened, updated, blocked, branch_is_main, no_review_signal, push_failed, gh_create_failed, zero_commits_halt, interrupted with signal-death rc)
SPEC-6[change]: pr_open_run returns rc∈{0,1} on every exit path; no return 2
SPEC-7[change]: pr-open reads review_report path from ZBUILD_STAGE_INPUTS when set; falls back to artifacts_dir construction when ZBUILD_STAGE_INPUTS is unset (library-call compat)
SPEC-8[change]: deploy-release manifest declares provides.result_contract==2 and provides.valid_verdicts is in config as [deployed,error] (unchanged from pre-migration value)
SPEC-9[change]: deploy-result.json carries result_contract:2, verdict, disposition, and non-empty reason on every exit path (dry_run, tag_success, tag_failed, push_failed, interrupted with signal-death rc)
SPEC-10[change]: deploy_release_run reads pr_url path from ZBUILD_STAGE_INPUTS when set; falls back to artifacts_dir construction when ZBUILD_STAGE_INPUTS is unset
SPEC-11[guard]: merge gate-absent or gate-non-pass path still delegates to pr_open_run and writes merge-result.json with verdict=pass, data.mode=pr_fallback rather than returning a hard error
SPEC-12[guard]: pr-open advisory mode (review-report.json present, review.json absent) still opens the PR successfully and renders advisory findings in the PR body
SPEC-13[guard]: pr-open zero-commit halt still writes pr-result.json with reason containing 'no committed changes' and gh is never invoked; returns non-zero
SPEC-14[guard]: deploy_release_run dry-run path still writes verdict=deployed in deploy-result.json when ZBUILD_DRY_RUN=1
SPEC-15[change]: merge manifest gains provides.events listing plugin.result (currently no provides block exists; the event is emitted by plugin.sh but undeclared)
SPEC-16[change]: deploy_release_run returns rc∈{0,1} on every exit path; the missing-state-file guard (currently return 2) becomes return 1
SPEC-17[guard]: deploy-release manifest retains provides.role==deploy_release_executor and provides.events==[deploy.release.complete,deploy.release.dry_run,release.published,release.tagged]
SPEC-18[guard]: pr-open manifest carries no role key (explicitly prohibited by manifest comment; this MUST remain true after migration)
SPEC-19[guard]: all three manifests carry tier_default:T0 and no router block; T0 satisfies the router-budget requirement by absence, consistent with mutation-gate/lint-gate/shape-floor pattern
SPEC-20[guard]: all three manifests have at least one output with primary:true declared (merge_result, pr_url, deploy_result respectively; already present before migration)
SPEC-21[guard]: cleanup hook is absent from all three manifest hooks sections; the plugin.sh cleanup stubs perform no work (T0 tools have no LLM state to clean; deliberate absence is correct)
SPEC-22[guard]: pr-open manifest retains provides.events==[plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work] after migration; no events removed or renamed
SPEC-23[change]: when gh squash-merge exits with signal-death rc (130/143/124) after the merge call was issued (outcome unknown — merge may have run), merge-result.json is written with disposition=unavailable and verdict=error; rc=1 is returned; the plugin does not guess whether the merge succeeded
SPEC-24[change]: when gh pr create or gh pr edit exits with signal-death rc (130/143/124) mid-flight (PR creation outcome unknown on remote), pr-result.json is written with disposition=unavailable and verdict=error; rc=1 is returned; the plugin does not guess whether the PR was created
SPEC-25[change]: when git push exits with signal-death rc (130/143/124) after a git tag was applied (tag state on remote unknown — push may have succeeded), deploy-result.json is written with disposition=unavailable and verdict=error; rc=1 is returned; the plugin does not guess whether the tag reached the remote
WIRING:
plugins/tool/merge/manifest.yaml
plugins/tool/pr-open/manifest.yaml
plugins/tool/deploy-release/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/merge-v2-result-test.sh
SPEC-2: tests/unit/merge-v2-result-test.sh
SPEC-3: tests/unit/merge-v2-result-test.sh
SPEC-4: tests/unit/pr-open-v2-result-test.sh tests/unit/lint-verdict-classify-test.sh
SPEC-5: tests/unit/pr-open-v2-result-test.sh
SPEC-6: tests/unit/pr-open-v2-result-test.sh
SPEC-7: tests/unit/pr-open-v2-result-test.sh
SPEC-8: tests/unit/deploy-release-v2-result-test.sh
SPEC-9: tests/unit/deploy-release-v2-result-test.sh
SPEC-10: tests/unit/deploy-release-v2-result-test.sh
SPEC-11: tests/unit/merge-v2-result-test.sh
SPEC-12: tests/unit/pr-open-advisory-review-test.sh
SPEC-13: tests/unit/pr-open-zero-commits-halts-test.sh
SPEC-14: tests/unit/deploy-release-v2-result-test.sh
SPEC-15: tests/unit/merge-v2-result-test.sh
SPEC-16: tests/unit/deploy-release-v2-result-test.sh
SPEC-17: tests/unit/deploy-release-v2-result-test.sh
SPEC-18: tests/unit/pr-open-v2-result-test.sh
SPEC-19: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-20: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-21: tests/unit/merge-v2-result-test.sh tests/unit/pr-open-v2-result-test.sh tests/unit/deploy-release-v2-result-test.sh
SPEC-22: tests/unit/pr-open-v2-result-test.sh
SPEC-23: tests/unit/merge-v2-result-test.sh
SPEC-24: tests/unit/pr-open-v2-result-test.sh
SPEC-25: tests/unit/deploy-release-v2-result-test.sh
```

LOOP_COMPLETE
