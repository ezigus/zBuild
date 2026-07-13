# monitor

The monitor plugin is a one-shot LLM health-assessment agent that reviews deployment artifacts and reports whether the deployed service is running as expected.

**Monitor Stage**

- **Kind:** `agent`
- **Role:** `monitor`
- **Manifest:** `plugins/agent/monitor/manifest.yaml`

## Manifest

```yaml
id: monitor
name: Monitor Stage
kind: agent
version: 0.1.0
description: |
  Monitor agent (kind:agent, T1). One-shot LLM health assessment (ADR-018 Pattern 1)
  over deploy artifacts already in state/artifacts/. Reads deploy-result.json (optional)
  and pr-url.txt (optional), calls route_to_model T1, and writes monitor-report.json
  (primary) with the verdict embedded (ADR-047 §3 — no separate verdict sidecar).
  ZBUILD_DRY_RUN=1 writes a mock report without calling route_to_model. Uses the shared
  llm-agent framework (ADR-028) for the OUTPUT CONTRACT + robust JSON-envelope parse;
  route_to_model owns redaction (ADR-043). Side-effecting probes (live HTTP polling,
  log tailing) are deferred to a future kind:tool plugin.
  # legacy-citation: pipeline-stages-monitor.sh:150 (stage_monitor)
  ADR-018 Pattern 1 (one-shot): assess → write report — no iteration loop.

hooks:
  init: monitor_stage_init
  run: monitor_stage_run
  finalize: monitor_stage_finalize
  cleanup: monitor_stage_cleanup

requires:
  core:
    - redaction
    - event-bus
    - state
    - router
  plugins: []

provides:
  artifact_type: monitor-report.json
  role: monitor
  schema_version: 1

config:
  tier_default: T1

inputs:
  - id: deploy_result
    type: file
    path: "${artifact_dir}/deploy-result.json"
    required: false
  - id: pr_url
    type: file
    source: stage:pr
    path: "${artifact_dir}/pr-url.txt"
    required: false

outputs:
  - id: monitor_report
    path: "${artifact_dir}/monitor-report.json"
    type: monitor-report.json
    required: true
    primary: true

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
