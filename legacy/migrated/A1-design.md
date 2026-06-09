# Migration Tombstone: A1 — Design Stage

- **Migration date:** 2026-06-08
- **Issue:** #754
- **Status:** complete

## Function mapping

| Legacy function | New location |
|---|---|
| `stage_design` (pipeline-stages-intake.sh:1004) | `plugins/agent/design/plugin.sh` — `design_stage_run` / `_design_stage_run_inner` |
| `_extract_scope_from_design` (pipeline-stages.sh:38-71) | `plugins/agent/build/plugin.sh` — `_extract_scope_from_design` |

## Remaining blockers

- [ ] 5-test trial complete (integration test added in same PR)
- [x] Legacy source removed (stage_design deleted from pipeline-stages-intake.sh)
- [x] Tombstone written
