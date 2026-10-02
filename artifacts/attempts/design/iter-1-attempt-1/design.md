# Design: migrate pr-delivery to contract v2 (#1844)

## Architectural decision summary

**Goal.** Adopt `result_contract: 2` in the pr-delivery plugin so it participates
in ADR-054/ADR-055 strictness: v2 result file on every exit path, `valid_verdicts`
narrowed from `[]` to `[pass, error]`, declared `provides.events`, input paths
resolved from `ZBUILD_STAGE_INPUTS`, `rc ∈ {0,1}` on all terminal paths, and fold
in #2250 (read pr-open verdict after delegation, not just rc).

**Context.** pr-delivery is the only remaining `kind: agent` plugin at the PR
delivery tier whose manifest still declares `valid_verdicts: []` and lacks
`provides.result_contract`. Its plugin.sh constructs two artifact paths by direct
string concatenation (`$artifacts_dir/gate-aggregator-result.json`,
`$artifacts_dir/review-report.json`) rather than reading the engine's
`ZBUILD_STAGE_INPUTS` index. The `review.json` path is intentionally a by-path
read (documented in both manifests; its producer was retired in #979 and the guard
is a fail-closed optional legacy check that must stay by-path). The plugin returns
`rc=2` on the missing-state-file path, which ADR-054 §4 forbids for v2 stages. The
block-guard, dry-run, fallback-gh, and missing-state-file paths write v1-format
results or no result. No signal trap exists. The three paths that delegate to
`merge_run` or `pr_open_run` rely on those tools to write pr-result.json — which
they already do in v2 format — but pr-delivery adds no wrapper. The `#2250` gap:
when `pr_open_run` returns rc=0 with `verdict=blocked` in pr-result.json (e.g., no
review signal present), pr-delivery currently treats the rc=0 as success and
returns 0 without PR delivery having occurred.

**Revision from prior design.** Three SPECs reclassified after verifying tree state:

- **SPEC-7** [change] → [guard]: `pr_open_run` (v2) already writes pr-result.json with
  `result_contract:2, verdict=error` on failure paths; the assertion passes at baseline.
- **SPEC-14** [change] → [guard]: `pr_open_run` (v2) already writes pr-result.json with
  `result_contract:2, verdict=pass` on success; assertion passes at baseline.
- **SPEC-15** [change] → [guard]: `merge_run` (v2) already writes pr-result.json with
  `result_contract:2, verdict=pass` on merge success; assertion passes at baseline.

New **SPEC-22[change]** added for #2250: pr-delivery must read the delegated
pr-result.json verdict after `pr_open_run` returns rc=0, and when verdict≠pass
(i.e., verdict=blocked — the no-review-signal or review-block case that pr-open
handles with rc=0), return rc=1 with verdict=error, disposition=complete,
reason=review_signal_missing.

**New ADRs (ADR-039, ADR-065) have no bearing on this migration.** ADR-039 is
about parallel stage groups; pr-delivery has no parallel-group membership.
ADR-065 constrains the engine's fork budget; pr-delivery does not run in the
fork-budget fixture (tests/e2e/fork-budget-test.sh).

**Decision.** Four-file migration following the established pattern (see
`plugins/tool/merge/`, `plugins/tool/pr-open/`):

- **manifest.yaml**: add `provides.result_contract: 2`, `provides.events:
  [pr.delivery.blocked, pr.delivery.opened, pr.delivery.dry_run]`, change
  `config.valid_verdicts` from `[]` to `[pass, error]`. No `router:` block —
  pr-delivery makes no direct LLM calls.
- **plugin.sh**: introduce `_pr_delivery_write_result` helper writing the v2
  envelope `{result_contract:2, verdict, disposition, reason, data:{...}}`;
  resolve `gate_aggregator_result` and `review_report` exclusively from
  `ZBUILD_STAGE_INPUTS` (review.json stays a by-path optional read); change
  `return 2` to `return 1` on missing-state-file and write verdict=error,
  disposition=misconfigured; install a
  `trap '_pr_delivery_write_result ... interrupted ... rc=1' SIGTERM SIGINT`
  at function entry; call `_pr_delivery_write_result` on every terminal exit
  path owned exclusively by pr-delivery (block guard, dry run, fallback-gh,
  missing-state-file, merge-delegation FAIL, SIGTERM). On the delegation
  success paths (merge, pr-open) where the delegate already wrote a v2 result,
  pr-delivery does NOT double-write — the delegate's result stands as the
  stage result. After `pr_open_run` returns rc=0, read pr-result.json verdict —
  if verdict≠pass (blocked), return rc=1 with verdict=error, disposition=complete,
  reason=review_signal_missing (#2250).
- **tests/unit/pr-delivery-v2-result-test.sh** (new): TDD-first unit test
  covering all [change] SPECs; written before touching the implementation.
- **tests/integration/pr-pipeline-test.sh**: add v2 envelope assertions to
  SPEC-3 (dry-run), SPEC-4 (block guard), SPEC-5 (delegation); update SPEC-9
  assertion from top-level `.draft` to `.data.draft`; add new SPEC-10 for
  the #2250 fold-in.

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
SPEC-6[change]: merge-delegation FAIL path writes pr-result.json carrying result_contract:2, verdict=error, non-empty disposition and reason (currently merge writes merge-result.json but NOT pr-result.json on its failure paths; pr-delivery writes nothing)
SPEC-7[guard]: pr-open-delegation FAIL path has pr-result.json carrying result_contract:2, verdict=error (pr-open already writes this; pr-delivery must not regress it)
SPEC-8[change]: fallback-gh-fail exit path writes pr-result.json carrying result_contract:2, verdict=error, disposition=unavailable
SPEC-9[change]: missing-state-file exit path returns rc=1 (not rc=2 as today)
SPEC-10[change]: plugin.sh resolves gate_aggregator_result and review_report exclusively via ZBUILD_STAGE_INPUTS — no hardcoded $artifacts_dir/gate-aggregator-result.json or $artifacts_dir/review-report.json constructions (review.json stays a by-path optional read per manifest comment)
SPEC-11[guard]: provides.role remains pr — no regression in stage resolution
SPEC-12[guard]: outputs.pr_url retains primary: true
SPEC-13[guard]: hooks section has run: pr_stage_run and no cleanup: entry
SPEC-14[guard]: pr-open delegation SUCCESS path has pr-result.json carrying result_contract:2, verdict=pass (pr-open already writes this; must not regress)
SPEC-15[guard]: merge delegation SUCCESS path has pr-result.json carrying result_contract:2, verdict=pass (merge already writes this; must not regress)
SPEC-16[change]: fallback-gh SUCCESS path writes pr-result.json carrying result_contract:2, verdict=pass, disposition=complete, non-empty reason (currently writes v1 format: {status, branch, pr_url, draft} with no result_contract/disposition/reason)
SPEC-17[change]: SIGTERM/SIGINT trap writes pr-result.json carrying result_contract:2, verdict=error, disposition=interrupted and exits rc=1 (no signal trap exists today)
SPEC-18[guard]: manifest has no router: block — pr-delivery makes no direct LLM calls; absence of router: is the explicit policy, not an omission
SPEC-19[change]: dry-run v2 pr-result.json carries .data.branch and .data.draft (v1 top-level fields preserved inside the v2 .data envelope — behavioral equivalence for the passing run)
SPEC-20[guard]: manifest inputs section declares only id and required: on each entry — no path, type, from, or producer field (name-matched inputs; the current manifest already satisfies this and the migration must not add such fields)
SPEC-21[change]: fallback-gh SUCCESS path v2 pr-result.json carries .data.branch, .data.pr_url, and .data.draft (v1 top-level fields preserved inside the v2 .data envelope)
SPEC-22[change]: when pr-open delegation returns rc=0 but pr-result.json verdict is not pass (verdict=blocked — no-review-signal or review-block handled by pr-open with rc=0), pr-delivery writes pr-result.json carrying result_contract:2, verdict=error, disposition=complete, reason=review_signal_missing and returns rc=1 (#2250: read pr-open verdict, not just rc)
WIRING:
plugins/agent/pr-delivery/manifest.yaml
TESTFILES:
SPEC-1: tests/unit/pr-delivery-v2-result-test.sh
SPEC-2: tests/unit/pr-delivery-v2-result-test.sh
SPEC-3: tests/unit/pr-delivery-v2-result-test.sh
SPEC-4: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-5: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-6: tests/unit/pr-delivery-v2-result-test.sh
SPEC-7: tests/unit/pr-delivery-v2-result-test.sh
SPEC-8: tests/unit/pr-delivery-v2-result-test.sh
SPEC-9: tests/unit/pr-delivery-v2-result-test.sh
SPEC-10: tests/unit/pr-delivery-v2-result-test.sh
SPEC-11: tests/unit/pr-delivery-v2-result-test.sh
SPEC-12: tests/unit/pr-delivery-v2-result-test.sh
SPEC-13: tests/unit/pr-delivery-v2-result-test.sh
SPEC-14: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-15: tests/unit/pr-delivery-v2-result-test.sh tests/integration/merge-policy-auto-test.sh
SPEC-16: tests/unit/pr-delivery-v2-result-test.sh
SPEC-17: tests/unit/pr-delivery-v2-result-test.sh
SPEC-18: tests/unit/pr-delivery-v2-result-test.sh
SPEC-19: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
SPEC-20: tests/unit/pr-delivery-v2-result-test.sh
SPEC-21: tests/unit/pr-delivery-v2-result-test.sh
SPEC-22: tests/unit/pr-delivery-v2-result-test.sh tests/integration/pr-pipeline-test.sh
```

```supersedes
tests/integration/pr-pipeline-test.sh [SPEC-9]: reads `.draft` at the top level of pr-result.json; after v2 migration the draft field moves to `.data.draft` inside the v2 envelope, making the top-level read return null instead of false
```

LOOP_COMPLETE
