# Migrated: §A — Stage Handler Files (full migration summary)

**Completed:** 2026-07-10
**EPIC:** §A migration of legacy/scripts/lib/pipeline-stages-*.sh to kind:agent/kind:tool plugins

## Migration arc

All legacy monolithic stage handlers under `legacy/scripts/lib/pipeline-stages-*.sh` have been
migrated to the plugin architecture (ADR-013, ADR-018). The legacy files are now removed.

## Issue-by-issue summary

| Keeper | Issue | Legacy file | New plugin(s) | Tombstone |
|---|---|---|---|---|
| A1 — design | #754 | pipeline-stages-design.sh | plugins/agent/design + plugins/tool/design-gate | A1-design.md |
| A2 — compound quality | #755 | pipeline-stages-cq.sh | plugins/agent/review-aggregator + review-lens | A2-compound-quality.md |
| A3 — pr delivery | #756 | pipeline-stages-delivery.sh (stage_pr) | plugins/agent/pr-delivery + plugins/tool/pr-open | A3-pr.md |
| A4 — deploy + validate | #757 | pipeline-stages-delivery.sh (stage_deploy) + pipeline-stages-monitor.sh (stage_validate) | plugins/agent/deploy + plugins/agent/validate | A4-deploy-validate.md |
| A5 — monitor | #758 | pipeline-stages-monitor.sh (stage_monitor) | plugins/agent/monitor | A5-monitor.md |
| A6 — template wiring | #1328 | — | config/templates/deployed.yaml (wires A4+A5 into production) | this file |

## Legacy files removed

- `legacy/scripts/lib/pipeline-stages-delivery.sh` — git rm in #1328 (2026-07-10); functions stage_resync, stage_pr, stage_merge migrated in prior issues; stage_deploy migrated in #757
- `legacy/scripts/lib/pipeline-stages-monitor.sh` — git rm in #1328 (2026-07-10); functions stage_validate + stage_monitor migrated in #757/#758

## Remaining legacy state

All `legacy/scripts/lib/pipeline-stages-*.sh` files that carried §A keepers have been removed.
The `legacy/.shipwright-disabled` sentinel remains. See `legacy/migrated/README.md` for the
full keeper registry.
