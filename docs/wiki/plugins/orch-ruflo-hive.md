# orch-ruflo-hive

**Orchestrator Backend — Ruflo Hive-Mind**

- **Kind:** `tool`
- **Role:** `orchestrator-backend`
- **Manifest:** `plugins/tool/orch-ruflo-hive/manifest.yaml`

## Manifest

```yaml
id: orch-ruflo-hive
name: Orchestrator Backend — Ruflo Hive-Mind
kind: tool
version: 0.1.0
description: |
  Orchestrator backend using ruflo hive-mind for coordination and local bash
  subshells for work unit execution. Hybrid model: ruflo hive-mind receives
  best-effort init/task/shutdown notifications while actual work units run as
  background bash processes with full stdout/stderr capture and exit-code
  propagation.

provides:
  role: orchestrator-backend
  alias: ruflo-hive
  capabilities: [parallel, hive_mind, distributed]

requires:
  bin: [ruflo]

config:
  fallback_to_default_on_error: true
  tier_default: T2
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
