---
migrated: 2026-06-22
issue: "#756"
branch: zbuild/issue-756-ci
---

# A3-pr — stage_pr migration tombstone

The `stage_pr` function from `legacy/scripts/lib/pipeline-stages-delivery.sh`
(lines 81–657) has been superseded by `plugins/agent/pr/` (kind:agent, T2).

## Function mapping

| Legacy function | New location |
|---|---|
| `stage_pr` (entry, lines 81–108) | `pr_stage_run` → `_pr_stage_run_inner` in `plugins/agent/pr/plugin.sh` |
| PR body composition + reviewer assignment | `_pr_stage_run_inner` (LLM-assisted, T2) |
| gh pr create invocation | delegated to `plugins/tool/pr-open/plugin.sh` (T0) |
| verdict guard (block refuses PR) | `_pr_stage_run_inner` review.json check |
| Dry-run / mock-gh mode | `ZBUILD_DRY_RUN=1` sentinel in `_pr_stage_run_inner` |
| Lifecycle init / finalize | `pr_stage_init` / `pr_stage_finalize` |

## ADR-013 amendment

`pr` kind updated: tool → agent, tier: T0 → T2 (#756).

## Remaining delivery functions in pipeline-stages-delivery.sh

The following functions in `legacy/scripts/lib/pipeline-stages-delivery.sh`
are NOT yet migrated and remain there pending future keeper issues:

- `stage_merge` (line 689+)
- `stage_deploy` (and any other delivery functions after line 657)

## Keeper trial checklist (5-test-trial)

1. [x] Behavior preserved — `pr-pipeline-test.sh` drives mock-gh dogfood run
2. [x] Regression test exists — `tests/integration/pr-pipeline-test.sh`
3. [x] Legacy-citation in `plugins/agent/pr/plugin.sh` header (line 16)
4. [x] ADR-013 amended (pr row: kind:tool→agent, tier:T0→T2)
5. [x] Removing plugin.sh reproduces SPEC-2 failure (by convention)
