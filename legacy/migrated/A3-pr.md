---
migrated: 2026-06-22
issue: "#756"
branch: zbuild/issue-756-ship
---

# A3-pr — stage_pr migration tombstone

The `stage_pr` function from `legacy/scripts/lib/pipeline-stages-delivery.sh`
(lines 81–657) has been superseded by `plugins/agent/pr-delivery/` (kind:agent,
T2). The plugin id is `pr-delivery` (not `pr`) to avoid colliding with the
existing `plugins/tool/pr-open` tool plugin, whose manifest id is `pr`; the
standard template's `pr` stage dispatches to it by role (`pr`).

## Function mapping

| Legacy function | New location |
|---|---|
| `stage_pr` (entry, lines 81–108) | `pr_stage_run` → `_pr_stage_run_inner` in `plugins/agent/pr-delivery/plugin.sh` |
| gh pr create invocation | delegated to `plugins/tool/pr-open/plugin.sh` (T0), with the run's state file threaded through |
| verdict guard (block refuses PR) | `_pr_stage_run_inner` review.json check |
| Dry-run / mock-gh mode | `ZBUILD_DRY_RUN=1` sentinel in `_pr_stage_run_inner` |
| Lifecycle init / finalize | `pr_stage_init` / `pr_stage_finalize` |

Note: the one-shot implementation guards on `review.json` and delegates the
actual PR open to `pr-open`. PR-body composition from `plan.json`/`design.md`
(declared as optional inputs) is reserved for a future change and is NOT yet
performed — the body passed to `gh pr create` is currently empty.

## ADR-013 amendment

`pr` kind updated: tool → agent, tier: T0 → T2 (#756).

## Remaining delivery functions in pipeline-stages-delivery.sh

The following functions in `legacy/scripts/lib/pipeline-stages-delivery.sh`
are NOT yet migrated and remain there pending future keeper issues:

- `stage_merge` (line 689+)
- `stage_deploy` (and any other delivery functions after line 657)

## Keeper trial checklist (5-test-trial)

1. [x] Behavior preserved — `pr-pipeline-test.sh` exercises the real plugin
       (dry-run + verdict guard + mock-gh pr-open delegation)
2. [x] Regression test exists — `tests/integration/pr-pipeline-test.sh`
3. [x] Legacy-citation in `plugins/agent/pr-delivery/plugin.sh` header
4. [x] ADR-013 amended (pr row: kind:tool→agent, tier:T0→T2)
5. [x] Removing plugin.sh reproduces SPEC-2 failure (by convention)
