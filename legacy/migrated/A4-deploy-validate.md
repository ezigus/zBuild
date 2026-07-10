# Migrated: A4 — deploy + validate stage handlers

**Date:** 2026-07-10
**Issue:** #757 (plugin authoring), #1328 (template wiring + legacy prune)
**Legacy source:** `legacy/scripts/lib/pipeline-stages-delivery.sh` (stage_deploy at line 950)
**Legacy source:** `legacy/scripts/lib/pipeline-stages-monitor.sh` (stage_validate at line 6)

## Function-by-function mapping

| Legacy function | New plugin | Path | Notes |
|---|---|---|---|
| `stage_deploy` (pipeline-stages-delivery.sh:950) | `deploy_agent_run` | `plugins/agent/deploy/plugin.sh` | ADR-018 P1; delegates to `deploy-release` tool; fail-closed gate guard |
| `stage_validate` (pipeline-stages-monitor.sh:6) | `validate_agent_run` | `plugins/agent/validate/plugin.sh` | ADR-018 P1; delegates to `health-check` tool; dry-run writes verdict=healthy |

## Wiring

- `plugins/agent/deploy/manifest.yaml` — role: deploy_agent, inputs: pr_url (from stage:pr), gate_aggregator_result (from stage:gate-aggregator, required:true)
- `plugins/agent/validate/manifest.yaml` — role: validate_agent, inputs: deploy_result (from stage:deploy, required:true)
- `config/templates/deployed.yaml` — extends simple; appends deploy → validate → monitor after pr (#1328)

## 5-test trial

Unit tests: `plugins/agent/deploy/tests/deploy-test.sh`, `plugins/agent/validate/tests/validate-test.sh`
Integration test: `tests/integration/deployed-template-e2e-test.sh` (dry-run dispatch, artifact + event assertions)
