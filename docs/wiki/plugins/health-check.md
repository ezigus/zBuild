# health-check

The health-check plugin performs the actual HTTP or smoke probe on behalf of the validate agent, returning raw output without making any model calls.

**Health Check Executor**

- **Kind:** `tool`
- **Role:** `health_check_executor`
- **Manifest:** `plugins/tool/health-check/manifest.yaml`

## Manifest

```yaml
id: health-check
name: Health Check Executor
kind: tool
version: 0.1.0
description: |
  Health-check tool executor (kind:tool, T0). Performs the actual HTTP/smoke
  probe and returns raw output for the validate agent to evaluate. No LLM calls.
  ZBUILD_DRY_RUN=1 returns a mock success response without executing the probe.
  Invoked by plugins/agent/validate/plugin.sh (health_check_run).
  Probe target URL is read from ZBUILD_HEALTH_CHECK_URL env var.
  Issue #757.

hooks:
  init: health_check_init
  run: health_check_run
  finalize: health_check_finalize
  cleanup: health_check_cleanup

requires:
  core:
    - event-bus
  plugins: []

provides:
  role: health_check_executor
  schema_version: 1

config:
  tier_default: T0

inputs: []

# health-check returns its probe result via stdout + exit code (consumed in-process
# by the validate agent); it writes NO file artifact. It therefore declares no
# provides.artifact_type and no file outputs — like the orch-*/cache-*/memory-*
# pure-function tool plugins. (validate-result.json is written by the validate
# AGENT, not by this tool.)
outputs: []

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
