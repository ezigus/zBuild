# orch-sequential

**Orchestrator Backend — Sequential**

- **Kind:** `tool`
- **Role:** `orchestrator-backend`
- **Manifest:** `plugins/tool/orch-sequential/manifest.yaml`

## Manifest

```yaml
id: orch-sequential
name: Orchestrator Backend — Sequential
kind: tool
version: 0.1.0
description: |
  Synchronous, in-process orchestrator backend.  Executes work units
  one at a time in the calling shell without spawning background jobs.
  Used as the default fallback backend and as a test double when the
  full bash-parallel backend is not required.

provides:
  role: orchestrator-backend
  alias: sequential
  capabilities: [sequential, fanout_sequential]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
