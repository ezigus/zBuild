# Design: Migrate compound_quality as 4 Agent Plugins

**ADR reference:** KEEPERS.md §A (re-cleave requirement), ADR-013 (canonical stage list)

---

## Goal

Decompose the 1013-line `stage_compound_quality` monolith (legacy) into four independently testable agent plugins (`cq-preflight`, `cq-audit-plan`, `cq-cycle`, `cq-backtrack`) wired sequentially into `review_cycle.flow` between `build_test_cycle` and `review`.

## Context

`compound_quality` exists as a single canonical stage id in `_ZBUILD_CANONICAL_STAGES` (template.sh:28) and ADR-013's stage table, but has never been added to `standard.yaml`. KEEPERS.md §A mandates a 4-phase split (pre-flight gates, audit-plan selection, cycle/plateau loop, backtrack-to-stage). This migration is Phase 1 work: add the 4 stages as leaf pipeline members and retire the legacy monolith.

## Decision

Add four `kind: agent` plugin directories under `plugins/agent/cq-{preflight,audit-plan,cycle,backtrack}/`. Wire them into `review_cycle.flow` after `build_test_cycle` and before `review`. Replace the single `compound_quality` entry in `_ZBUILD_CANONICAL_STAGES` with the four new ids (`cq-preflight cq-audit-plan cq-cycle cq-backtrack`). Update ADR-013, all tests that pin stage counts or canonical stage lists, then prune the legacy source and write the migration tombstone.

---

## Stage contract per plugin

| Stage id | Plugin dir | Responsibility | Exits on |
|---|---|---|---|
| `cq-preflight` | `plugins/agent/cq-preflight` | bash-compat check, coverage floor, untested-function scan. Fail-fast; never enters cycle. | verdict: pass \| fail |
| `cq-audit-plan` | `plugins/agent/cq-audit-plan` | Read `quality-scores.jsonl` history; emit `audit-plan.json` selecting lens set and intensity. | always continue |
| `cq-cycle` | `plugins/agent/cq-cycle` | Execute lens cycle with plateau/convergence/divergence detection; write `cq-cycle-result.json`. | verdict: pass \| max_iter |
| `cq-backtrack` | `plugins/agent/cq-backtrack` | Classify findings by category; emit `cq-backtrack.json` routing architecture findings back to design. | verdict: clean \| routed |

## standard.yaml wiring

`review_cycle.flow` changes from `[build_test_cycle, review]` to:

```yaml
flow:
  - build_test_cycle
  - cq-preflight
  - cq-audit-plan
  - cq-cycle
  - cq-backtrack
  - review
```

Each CQ stage is declared as a top-level leaf section (gate: auto, kind: agent) alongside the existing leaf sections. No new cycle wrapper — the 4 stages run sequentially inside the outer `review_cycle` iteration.

## Stage count impact

| Counter | Before | After |
|---|---|---|
| `_ZBUILD_CANONICAL_STAGES` | 13 (`compound_quality` present, not in standard.yaml) | 16 (replace 1 with 4) |
| `_TPL_STAGES` flat for standard.yaml | 8 | 12 |
| `_TPL_CYCLES` for standard.yaml | 3 | 3 (unchanged) |

`_TPL_DISPATCH_UNITS` for the outer flow stays `stage:intake cycle:plan_impact_cycle stage:design cycle:review_cycle` — the 4 CQ stages are members of `review_cycle`, not top-level dispatch units.

## Test update summary

| File | Change |
|---|---|
| `core-pipeline-template-test.sh` | `"8 stages"` → `"12 stages"` |
| `core-pipeline-template-cycles-test.sh` | `"8 stages"` → `"12 stages"`; `expected_flat` adds 4 CQ ids before `review` |
| `docs-adr-013-test.sh` | TC-3 `canonical_stages` replaces `compound_quality` with 4 CQ ids; TC-5 updated to match new ADR-013 text |
| `full-pipeline-seq-cardinal-test.sh` | stage-count assertions updated |
| `core-pipeline-runner-test.sh` | any pinned stage-list or count assertion updated |
| `core-pipeline-verdict-indicators-test.sh` | any `compound_quality` reference updated |
| `full-pipeline-cycle-seq-3level-test.sh` | stage-sequence assertions updated |
| `review-remediation-cycle-test.sh` | updated to expect CQ stages inside review_cycle |
| `compound-quality-pipeline-test.sh` | **new** integration test; runs `review_cycle` stub with all 4 CQ stages and asserts artifact chain |

## Legacy pruning

- `legacy/scripts/lib/pipeline-intelligence.sh` — `git rm` the `stage_compound_quality` block (lines `:1959-2972`); leave `pipeline_select_audits` intact (used by `cq-audit-plan`).
- `legacy/scripts/lib/pipeline-stages-review.sh` — remove any compound_quality dispatch shim.
- `legacy/migrated/A2-compound-quality.md` — create tombstone with date + issue link (pruning protocol per KEEPERS.md §N).

---

```scope
config/templates/standard.yaml
core/pipeline/template.sh
docs/adr/ADR-013-canonical-stage-list.md
docs/KEEPERS.md
legacy/migrated/A2-compound-quality.md
legacy/scripts/lib/pipeline-intelligence.sh
legacy/scripts/lib/pipeline-stages-review.sh
plugins/agent/cq-audit-plan/manifest.yaml
plugins/agent/cq-audit-plan/plugin.sh
plugins/agent/cq-backtrack/manifest.yaml
plugins/agent/cq-backtrack/plugin.sh
plugins/agent/cq-cycle/manifest.yaml
plugins/agent/cq-cycle/plugin.sh
plugins/agent/cq-preflight/manifest.yaml
plugins/agent/cq-preflight/plugin.sh
scripts/lib/lint-contract.sh
tests/integration/compound-quality-pipeline-test.sh
tests/integration/core-pipeline-runner-test.sh
tests/integration/core-pipeline-verdict-indicators-test.sh
tests/integration/full-pipeline-cycle-seq-3level-test.sh
tests/integration/full-pipeline-seq-cardinal-test.sh
tests/integration/review-remediation-cycle-test.sh
tests/unit/core-pipeline-template-cycles-test.sh
tests/unit/core-pipeline-template-test.sh
tests/unit/docs-adr-013-test.sh
```

LOOP_COMPLETE
