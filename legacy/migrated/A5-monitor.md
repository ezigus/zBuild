# Migrated: A5 — monitor stage handler

**Date:** 2026-07-10
**Issue:** #758 (plugin authoring), #1328 (template wiring + legacy prune)
**Legacy source:** `legacy/scripts/lib/pipeline-stages-monitor.sh` (stage_monitor at line 150)

## Function-by-function mapping

| Legacy function | New plugin | Path | Notes |
|---|---|---|---|
| `stage_monitor` (pipeline-stages-monitor.sh:150) | `monitor_stage_run` | `plugins/agent/monitor/plugin.sh` | ADR-018 P1; one-shot T1 LLM assessment; uses llm-agent.sh shared framework (ADR-028); dry-run writes verdict=pass |

## Wiring

- `plugins/agent/monitor/manifest.yaml` — role: monitor, inputs: deploy_result (optional, from stage:deploy), pr_url (optional, from stage:pr)
- `config/templates/deployed.yaml` — extends simple; appends monitor as the third post-PR stage (#1328)

## 5-test trial

Unit tests: `plugins/agent/monitor/tests/monitor-test.sh`
Integration test: `tests/integration/deployed-template-e2e-test.sh` (dry-run dispatch, artifact + event assertions)
