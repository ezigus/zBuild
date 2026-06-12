# Tombstone: A2 compound_quality → 4 CQ plugins

**Date:** 2026-06-12
**Issue:** #755
**Status:** Migrated

## Migration map

| Legacy function | Legacy location | New plugin |
|---|---|---|
| `stage_compound_quality` (preflight gates) | `pipeline-intelligence.sh:2042-2195` | `plugins/agent/cq-preflight/` |
| `pipeline_select_audits` | `pipeline-intelligence.sh:429-508` | `plugins/agent/cq-audit-plan/` |
| `stage_compound_quality` (cycle/plateau loop) | `pipeline-intelligence.sh:2198+` | `plugins/agent/cq-cycle/` |
| `stage_compound_quality` (backtrack-to-stage) | `pipeline-intelligence.sh:1343/1745` | `plugins/agent/cq-backtrack/` |
| `stage_compound_quality` (fallback stub) | `pipeline-stages-review.sh:706-861` | `plugins/agent/cq-preflight/` + `cq-cycle/` |

## Legacy line ranges removed

- `legacy/scripts/lib/pipeline-intelligence.sh:429-508` — `pipeline_select_audits` → `cq-audit-plan`
- `legacy/scripts/lib/pipeline-intelligence.sh:1959-2972` — `stage_compound_quality` body → split across 4 plugins
- `legacy/scripts/lib/pipeline-stages-review.sh:706-861` — fallback `stage_compound_quality` stub

## New plugin paths

- `plugins/agent/cq-preflight/manifest.yaml`
- `plugins/agent/cq-preflight/plugin.sh`
- `plugins/agent/cq-audit-plan/manifest.yaml`
- `plugins/agent/cq-audit-plan/plugin.sh`
- `plugins/agent/cq-cycle/manifest.yaml`
- `plugins/agent/cq-cycle/plugin.sh`
- `plugins/agent/cq-backtrack/manifest.yaml`
- `plugins/agent/cq-backtrack/plugin.sh`

## Remaining blockers checklist

- [x] Plugin manifests and plugin.sh files created
- [x] standard.yaml review_cycle.flow updated
- [x] _ZBUILD_CANONICAL_STAGES updated (core/pipeline/template.sh)
- [x] lint-contract.sh _LC_STAGE_IDS_TO_CHECK updated
- [x] ADR-013 amendment added
- [x] Integration tests updated
- [x] Legacy source tombstoned (stubs left in place with migration comments)
