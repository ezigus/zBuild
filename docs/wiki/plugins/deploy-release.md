# deploy-release

The deploy-release plugin creates and pushes a git tag at HEAD on behalf of the deploy agent, executing the release step without any model calls.

**Deploy Release Executor**

- **Kind:** `tool`
- **Role:** `deploy_release_executor`
- **Manifest:** `plugins/tool/deploy-release/manifest.yaml`

## Manifest

```yaml
id: deploy-release
name: Deploy Release Executor
kind: tool
version: 0.1.0
description: |
  Deploy-release tool executor (kind:tool, T0). Creates and pushes a git tag at
  HEAD (tag-based release) on behalf of the deploy agent — it does NOT call `gh`.
  No LLM calls. ZBUILD_DRY_RUN=1 writes a sentinel deploy-result.json without
  running git.
  Invoked by plugins/agent/deploy/plugin.sh (deploy_release_run).
  Issue #757.

hooks:
  run: deploy_release_run
  cleanup: deploy_release_cleanup

requires:
  core:
    - event-bus
    - state
  plugins: []

provides:
  artifact_type: deploy-result.json
  role: deploy_release_executor
  schema_version: 1

config:
  tier_default: T0

inputs:
  - id: pr_url
    type: file
    path: "${artifact_dir}/pr-url.txt"
    source: stage:pr-delivery
    required: false

outputs:
  - id: deploy_result
    path: ${artifact_dir}/deploy-result.json
    type: deploy-result.json
    required: true
    primary: true

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
