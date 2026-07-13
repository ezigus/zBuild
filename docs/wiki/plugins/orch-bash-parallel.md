# orch-bash-parallel

The orch-bash-parallel plugin is a parallel orchestrator backend that dispatches work units as background bash processes and collects their results.

**Orchestrator Backend — Bash Parallel**

- **Kind:** `tool`
- **Role:** `orchestrator-backend`
- **Manifest:** `plugins/tool/orch-bash-parallel/manifest.yaml`

## Manifest

```yaml
id: orch-bash-parallel
name: Orchestrator Backend — Bash Parallel
kind: tool
version: 0.1.0
description: |
  Parallel orchestrator backend using background bash jobs. Dispatches work
  units as background processes writing results to a pool directory; collects
  results by polling for .exit files (no wait on PIDs — safe across subshell
  boundaries).

provides:
  role: orchestrator-backend
  alias: bash-parallel
  capabilities: [parallel, fanout_parallel]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
