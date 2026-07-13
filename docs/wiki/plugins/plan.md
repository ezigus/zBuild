# plan

The plan plugin is the pipeline's planning agent, reading a scope manifest and goal to produce a structured plan.json artifact that drives the build stage.

**Plan Stage**

- **Kind:** `agent`
- **Manifest:** `plugins/agent/plan/manifest.yaml`

## Manifest

```yaml
id: plan
name: Plan Stage
kind: agent
version: 0.1.0
description: |
  Plan stage agent (ADR-013, T2). Consumes a scope-manifest and goal text,
  routes to the T2 model tier, and produces a plan.json artifact describing
  the ordered implementation steps, file estimates, and notes.

hooks:
  init: plan_init
  run: plan_run
  finalize: plan_finalize
  cleanup: plan_cleanup

requires:
  core:
    - redaction
    - event-bus
    - state
    - router
  plugins: []

provides:
  artifact_type: plan.json
  schema_version: 1

config:
  tier_default: T2

inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
  - id: goal_string
    type: string
    source: external
    required: true

outputs:
  - id: plan
    path: ${artifact_dir}/plan.json
    type: plan.json
    required: true
    # ADR-020 amendment (#507): primary output. plan.json has no .verdict
    # field; runner falls back to pass when JSON is present and well-formed.
    primary: true
  # #1052: secondary, non-primary resumable exploration artifact. Persisted on
  # every terminal plan outcome (complete | scope_too_large) so a rerun can
  # resume from prior exploration instead of re-deriving from scratch. NOT
  # primary — plan.json stays the verdict-bearing primary (ADR-020 intact).
  # GitHub-artifact naming contract (Pillar E): when uploaded, the artifact
  # path must include <repo_id>/<scope_key>/<goal_hash> so two pipelines'
  # uploads never collide in a shared artifacts bucket.
  - id: plan-context
    path: ${artifact_dir}/plan-context.json
    type: plan-context.json
    required: false

state:
  persisted: [last_plan_steps, plan_context_status]
  reconstructed: [goal_text]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
