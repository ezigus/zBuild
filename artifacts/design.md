# Design: Migrate merge, pr-open, deploy-release to contract v2

## Architectural Decision Summary

**Goal.** Promote three T0 tool plugins — `plugins/tool/merge`, `plugins/tool/pr-open`, and
`plugins/tool/deploy-release` — from the informal v1 result convention to the ADR-054 / ADR-055
contract v2: `result_contract:2` in each manifest's `provides:` block; every exit path writes
`verdict`, `disposition`, and `reason`; exit codes narrowed to `{0,1}`; declared inputs read
from `ZBUILD_STAGE_INPUTS` rather than hardcoded `$artifacts_dir/<name>` path constructions.

**Context.** This is issue #1849, the final PR in the 17-issue F-wave migration series
(ADR-055 §1). Existing v2-migrated T0 peers — `mutation-gate`, `lint-gate`, `shape-floor`,
`teardown` — establish the reference pattern. The three plugins in scope are internally dispatched
(pr-delivery sources merge and pr-open; deploy agent sources deploy-release) so `plugin_hook_call`
never fires for them, but `provides.result_contract:2` still gates the engine's result-reading
behaviour. The `review.json` and `gate-aggregator-result.json` reads are documented as BY-PATH
(not declared inputs) and are explicitly out of scope for the paths-in-code requirement. A
non-obvious side-effect: adding `blocked` to pr-open's `valid_verdicts` requires adding it to
`core/pipeline/verdict.sh`'s `verdict_classify` function and the pinned ADR-019 table; without
this, `scripts/lib/lint-verdict-classify.sh` fails the CI Lint job.

**Decision.** For each plugin: (1) add `result_contract:2` and populated `valid_verdicts` to
`provides:` in the manifest — merge also gains `role: merge_executor` (required per ADR-001
/#1704); (2) every `jq` result write in `plugin.sh` gains `result_contract:2`, `verdict`,
`disposition`, and `reason` with plugin-specific payload fields relocated under `data:`; (3) all
`return 2` sites become `return 1`; (4) each declared input (merge's `gate_aggregator_result`,
pr-open's `review_report`, deploy-release's `pr_url`) is resolved via a `ZBUILD_STAGE_INPUTS`
lookup plus `$artifacts_dir` fallback so library-call callers (pr-delivery, deploy agent) that
skip `plugin_hook_call` continue to work. TDD order per step: write the v2 result test, confirm
it fails at baseline, implement, confirm it goes green.

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
tests/unit/pr-open-advisory-review-test.sh
tests/unit/pr-open-zero-commits-halts-test.sh
tests/unit/template-merge-policy-test.sh
plugins/tool/pr-open/tests/pr-open-test.sh
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

`core/pipeline/verdict.sh` — pr-open's new `valid_verdicts: [pass, blocked, error]` adds `blocked`
as a declared verdict. `scripts/lib/lint-verdict-classify.sh` (wired into CI Lint) fails when any
declared verdict does not classify to a known class. `blocked` is absent from `verdict_classify`;
it must be added to both the case arm (`fail|error|block|blocked|...`) and the pinned ADR-019
comment table, or the build fails as soon as the manifest change lands.

`tests/unit/lint-verdict-classify-test.sh` — SPEC-2 in this test runs lint-verdict-classify.sh
over all plugins; after pr-open's manifest adds `blocked`, the lint would fail without the
verdict.sh change. In scope to confirm the combined change keeps the test green.

`plugins/tool/pr-open/tests/pr-open-test.sh` — asserts `"schema_version": 1` and `".status"`
values on `pr-result.json`; after v2, `status` moves to `data.status` and `result_contract:2`
is added. These assertions break.

`tests/integration/merge-policy-auto-test.sh` and `merge-policy-auto-unless-flagged-test.sh` —
assert `jq -r '.status // empty'` on `merge-result.json`; after v2, `status` moves to
`data.status` and those assertions produce empty string → test failures.

`tests/integration/pr-pipeline-test.sh` — asserts `rc=2` from `pr_open_run` (SPEC-4, SPEC-6)
and reads `.draft` directly from `pr-result.json`; rc=2 → 1 breaks the rc assertion; `.draft`
moves to `data.draft`.

`tests/unit/pr-open-zero-commits-halts-test.sh` — asserts `rc=2` from `pr_open_run` (its
SPEC-8); rc=2 → 1 breaks the assertion. The halt behavior is unchanged; only the code changes.

`tests/unit/pr-open-advisory-review-test.sh` — asserts `.status == "opened"` on `pr-result.json`
output; after v2 `.status` is under `data.status`.

`tests/unit/plugin-artifact-goldens-test.sh` G4 and `tests/golden/pr-result-artifact.golden` —
G4 checks `schema_version == 1` and exact-matches the pr-result golden; the golden encodes
`"status":"opened"` at top level which moves to `data.status` in v2. Golden and assertion need
updating together.

`docs/adr/ADR-054-stage-contract.md` / `ADR-055-inter-stage-data-contract-v2.md` — are the
authoritative specification references for the contract being implemented. In scope as the docs
that describe and motivate every constraint; a reader auditing the PR must be able to locate them.
Wiki pages describe the plugin contracts; a reviewer confirming behaviour against the wiki must
see whether the wiki is accurate post-migration.

```acceptance
SPEC-1[change]: merge manifest declares provides.result_contract==2, valid_verdicts==[pass,error], and provides.role==merge_executor
SPEC-2[change]: merge-result.json carries result_contract:2, verdict, disposition, and non-empty reason on every exit path (merged, pr_fallback, branch_is_main, push_failed, gh_create_failed, gh_merge_failed)
SPEC-3[change]: merge_run returns rc∈{0,1} on every exit path; no return 2
SPEC-4[change]: pr-open manifest declares provides.result_contract==2 and valid_verdicts==[pass,blocked,error]; verdict_classify('blocked') returns 'fail' (not 'unknown')
SPEC-5[change]: pr-result.json carries result_contract:2, verdict, disposition, and non-empty reason on every exit path (opened, updated, blocked, branch_is_main, no_review_signal, push_failed, gh_create_failed, zero_commits_halt)
SPEC-6[change]: pr_open_run returns rc∈{0,1} on every exit path; no return 2
SPEC-7[change]: pr-open reads review_report path from ZBUILD_STAGE_INPUTS when set; falls back to artifacts_dir construction when ZBUILD_STAGE_INPUTS is unset (library-call compat)
SPEC-8[change]: deploy-release manifest declares provides.result_contract==2
SPEC-9[change]: deploy-result.json written by deploy_release_run carries result_contract:2, disposition, and non-empty reason on every exit path (dry_run, tag_success, tag_failed, push_failed)
SPEC-10[change]: deploy_release_run reads pr_url path from ZBUILD_STAGE_INPUTS when set; falls back to artifacts_dir construction when ZBUILD_STAGE_INPUTS is unset
SPEC-11[guard]: merge gate-absent or gate-non-pass path still delegates to pr_open_run and writes merge-result.json with verdict=pass, data.mode=pr_fallback rather than returning a hard error
SPEC-12[guard]: pr-open advisory mode (review-report.json present, review.json absent) still opens the PR successfully and renders advisory findings in the PR body
SPEC-13[guard]: pr-open zero-commit halt still writes pr-result.json with reason containing 'no committed changes' and gh is never invoked; returns non-zero
SPEC-14[guard]: deploy_release_run dry-run path still writes verdict=deployed in deploy-result.json when ZBUILD_DRY_RUN=1
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
```

LOOP_COMPLETE
