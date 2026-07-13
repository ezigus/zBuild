# orch-mock

The orch-mock plugin is a deterministic, synchronous orchestrator backend used exclusively in tests to verify the orchestrator contract without spawning any processes.

**Orchestrator — Mock (test-only synchronous backend)**

- **Kind:** `tool`
- **Role:** `orchestrator-backend`
- **Manifest:** `plugins/tool/orch-mock/manifest.yaml`

## Manifest

```yaml
id: orch-mock
name: Orchestrator — Mock (test-only synchronous backend)
kind: tool
version: 0.1.0
description: |
  Deterministic, synchronous orchestrator backend used exclusively by
  tests/unit/core-orch-contract-test.sh and
  tests/integration/core-orch-contract-test.sh.

  Work units are bash function bodies serialized as newline-free strings
  (see "work unit definition" in tests/unit/core-orch-contract-test.sh).
  orch_dispatch executes each work unit synchronously in a subshell so
  tests never depend on timing, background jobs, or external processes.

  NOT for production use.  The real default is plugins/tool/orch-bash-parallel
  (issue #220).

hooks:
  init: orch_mock_init
  run: orch_mock_run

provides:
  role: orchestrator-backend
  alias: mock-orch
  capabilities: [sequential, fanout]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
