# Migration Tombstone: A1-design

**Migration date:** 2026-06-10
**Issue:** #754

## Function mapping

| Legacy function | Migrated to |
|---|---|
| `stage_design` (pipeline-stages-intake.sh:1004) | `plugins/agent/design/plugin.sh` — `design_stage_init`, `design_stage_run`, `_design_stage_run_inner`, `design_stage_finalize`, `design_stage_cleanup` |
| `_extract_scope_from_design` (pipeline-stages.sh:38-71) | `plugins/agent/design/plugin.sh` — `_extract_scope_from_design` + `plugins/agent/build/plugin.sh` — `_extract_scope_from_design` |

## Remaining blockers

- `stage_design` was NOT found at pipeline-stages-intake.sh:1004 at migration time.
  The cited line is a TDD comment block, not a live function definition.
  Legacy citation comments in plugin.sh are preserved for auditability but do not
  correspond to executable code at that line.
- `pipeline-stages-intake.sh` cannot be `git rm`'d because `stage_intake` (line 6)
  and `stage_plan` (line 174) remain unmigrated. The `git rm` of the legacy source
  is deferred to the issues that migrate those two functions.

## 5-trial checklist

- [x] Plugin produces design.md with a ```scope block (design-pipeline-test.sh assertion 2+3)
- [x] Scope block is a superset of plan.json steps[].files[] (design-pipeline-test.sh assertion 3)
- [x] plugin.run.start plugin=design appears in events.jsonl (design-pipeline-test.sh assertion 1)
- [x] standard.yaml flow: contains 'design' between plan_impact_cycle and review_cycle
- [x] KEEPERS §A.6 mapping accurate — KEEPERS.md row for design points at plugins/agent/design/; path exists
