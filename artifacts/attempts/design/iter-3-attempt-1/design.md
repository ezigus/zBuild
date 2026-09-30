# Design: migrate pr-delivery to contract v2 (#1844)

## Architectural decision summary

**Goal.** Adopt `result_contract: 2` in the pr-delivery plugin so it participates
in ADR-054/ADR-055 strictness: v2 result file on every exit path, `valid_verdicts`
narrowed from `[]` to `[pass, error]`, declared `provides.events`, input paths
resolved from `ZBUILD_STAGE_INPUTS`, and `rc ∈ {0,1}` on all terminal paths.

**Context.** pr-delivery is the only remaining `kind: agent` plugin at the PR
delivery tier whose manifest still declares `valid_verdicts: []` and lacks
`provides.result_contract`. Its plugin.sh constructs three artifact paths by
direct string concatenation (`$artifacts_dir/review.json`,
`$artifacts_dir/gate-aggregator-result.json`,
`$artifacts_dir/review-report.json`) rather than reading the engine's
`ZBUILD_STAGE_INPUTS` index. It also returns `rc=2` on the missing-state-file
path, which ADR-054 §4 forbids for v2 stages. Success paths (merge-delegation,
pr-open-delegation) write nothing to pr-result.json; the fallback-gh success path
writes a v1-format result with top-level `{status, branch, pr_url, draft}` fields.
No signal trap exists. The three sibling plugins it delegates to (`merge`,
`pr-open`) are already v2; pr-delivery itself is the gap.

**Decision.** Four-file migration following the established pattern (see
`plugins/tool/merge/`, `plugins/tool/pr-open/`):
- **manifest.yaml**: add `provides.result_contract: 2`, `provides.events:
  [pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run]`, change
  `config.valid_verdicts` from `[]` to `[pass, error]`. Inputs remain declared
  with only `id` and `required:` — no `path`, `type`, or `from/producer` field
  (name-matched inputs, per ADR-055 §"Name-matched inputs"). No `router:` block
  added: pr-delivery makes no direct LLM calls; this criterion is explicitly
  inapplicable.
- **plugin.sh**: introduce `_pr_delivery_write_result` helper writing the v2
  envelope `{result_contract:2, verdict, disposition, reason, data:{...}}`;
  resolve `review_report` and `gate_aggregator_result` inputs exclusively from
  `ZBUILD_STAGE_INPUTS`; remove all three hardcoded input-path constructions;
  change the missing-state-file `return 2` to `return 1`; install a
  `trap '_pr_delivery_write_result ... interrupted ... rc=1' SIGTERM SIGINT`
  at function entry; call `_pr_delivery_write_result` on every terminal exit
  path — including the pr-open SUCCESS, merge SUCCESS, and fallback-gh SUCCESS
  paths which currently write nothing or a v1 envelope — with appropriate
  `verdict` (`pass`/`error`) and `disposition`
  (`complete`/`interrupted`/`unavailable`/`precondition_unmet`). On the
  fallback-gh SUCCESS path, v1 top-level fields (`branch`, `pr_url`, `draft`)
  are preserved inside `.data` for downstream behavioral equivalence.
- **tests/unit/pr-delivery-v2-result-test.sh** (new): TDD-first unit test
  covering all SPECs; written before touching the implementation; confirmed
  red at the merge-base.
- **tests/integration/pr-pipeline-test.sh**: add v2 envelope assertions to
  SPEC-3, SPEC-4, SPEC-5; update SPEC-9 to read `.data.draft` now that the
  `draft` field moves inside `.data` under the v2 envelope; add [#1844/SPEC-14]
  and [#1844/SPEC-19] tagged assertions to the SPEC-5 block.

```scope
plugins/agent/pr-delivery/manifest.yaml
plugins/agent/pr-delivery/plugin.sh
tests/unit/pr-delivery-v2-result-test.sh
tests/integration/pr-pipeline-test.sh
tests/integration/merge-policy-auto-test.sh
tests/integration/merge-policy-auto-unless-flagged-test.sh
docs/wiki/plugins/pr-delivery.md
docs/adr/ADR-013-canonical-stage-list.md
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-055-inter-stage-data-contract-v2.md
```

```acceptance
SPEC-1[change]: manifest provides.result_contract is 2
SPEC-2[change]: manifest config.valid_verdicts is [pass, error] — no longer the empty list
SPEC-3[change]: manifest provides.events declares pr.delivery.blocked, pr.delivery.opened, and pr.delivery.dry_run
SPEC-4[change]: block guard exit path writes pr-result.json carrying result_contract:2, verdict=error, non-empty disposition, non-empty reason
SPEC-5[change]: dry-run exit path writes pr-result.json carrying result_contract:2, verdict=pass, non-empty disposition, non-empty reason
SPEC-6[change]: merge-delegation FAIL path writes pr-result.json carrying result_contract:2, verdict=error, non-empty disposition and reason (currently writes nothing, only stage_summary_write)
SPEC-7[change]: pr-open-delegation FAIL path writes pr-result.json carrying result_contract:2, verdict=error, non-empty disposition and reason (currently writes nothing, only stage_summary_write)
SPEC-8[change]: fallback-gh-fail exit path writes pr-result.json carrying result_contract:2, verdict=error, disposition=unavailable
SPEC-9[change]: missing-state-file exit path returns rc=1 (not rc=2 as today)
SPEC-10[change]: plugin.sh constructs no hardcoded review.json, gate-aggregator-result.json, or review-report.json paths — inputs resolved only via ZBUILD_STAGE_INPUTS
SPEC-11[guard]: provides.role remains pr — no regression in stage resolution
SPEC-12[guard]: outputs.pr_url retains primary: true
SPEC-13[guard]: hooks section has run: pr_stage_run and no cleanup: entry
SPEC-14[change]: pr-open delegation SUCCESS path writes pr-result.json carrying result_contract:2, verdict=pass, disposition=complete (currently writes nothing — only stage_summary_write)
SPEC-15[change]: merge delegation SUCCESS path writes pr-result.json carrying result_contract:2, verdict=pass, disposition=complete (currently writes nothing — only stage_summary_write)
SPEC-16[change]: fallback-gh SUCCESS path writes pr-result.json carrying result_contract:2, verdict=pass, disposition=complete, non-empty reason (currently writes v1 format: {status, branch, pr_url, draft} with no result_contract/disposition/reason)
SPEC-17[change]: SIGTERM/SIGINT trap writes pr-result.json carrying result_contract:2, verdict=error, disposition=interrupted and exits rc=1 (no signal trap exists today)
SPEC-18[guard]: manifest has no router: block — pr-delivery makes no direct LLM calls; absence of router: is the explicit policy, not an omission
SPEC-19[change]: dry-run v2 pr-result.json carries .data.branch and .data.draft (v1 top-level fields preserved inside the v2 .data envelope — behavioral equivalence for the passing run)
SPEC-20[guard]: manifest inputs section declares only id and required: on each entry — no path, type, from, or producer field (name-matched inputs; the current manifest already satisfies this and the migration must not add such fields)
SPEC-21[change]: fallback-gh SUCCESS path v2 pr-result.json carries .data.branch, .data.pr_url, and .data.draft (v1 top-level fields preserved inside the v2 .data envelope — behavioral equivalence for the fallback-gh passing run; currently these fields are written at the top level, not under .data)
WIRING:
plugins/agent/pr-delivery/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/pr-delivery-v2-result-test.sh
SPEC-2: tests/unit/pr-delivery-v2-result-test.sh
SPEC-3: tests/unit/pr-delivery-v2-result-test.sh
SPEC-4: tests/unit/pr-delivery-v2-result-test.sh
SPEC-5: tests/unit/pr-delivery-v2-result-test.sh
SPEC-6: tests/unit/pr-delivery-v2-result-test.sh
SPEC-7: tests/unit/pr-delivery-v2-result-test.sh
SPEC-8: tests/unit/pr-delivery-v2-result-test.sh
SPEC-9: tests/unit/pr-delivery-v2-result-test.sh
SPEC-10: tests/unit/pr-delivery-v2-result-test.sh
SPEC-11: tests/unit/pr-delivery-v2-result-test.sh
SPEC-12: tests/unit/pr-delivery-v2-result-test.sh
SPEC-13: tests/unit/pr-delivery-v2-result-test.sh
SPEC-14: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-15: tests/unit/pr-delivery-v2-result-test.sh
SPEC-16: tests/unit/pr-delivery-v2-result-test.sh
SPEC-17: tests/unit/pr-delivery-v2-result-test.sh
SPEC-18: tests/unit/pr-delivery-v2-result-test.sh
SPEC-19: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-20: tests/unit/pr-delivery-v2-result-test.sh
SPEC-21: tests/unit/pr-delivery-v2-result-test.sh
```

```supersedes
tests/integration/pr-pipeline-test.sh [SPEC-9]: reads `.draft` at the top level of pr-result.json; after v2 migration the draft field moves to `.data.draft` inside the v2 envelope, making the top-level read return null instead of false
```

LOOP_COMPLETE
