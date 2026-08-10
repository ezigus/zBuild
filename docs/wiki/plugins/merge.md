# merge

The merge plugin automatically merges a pull request when the gate-aggregator verdict is pass and the template's merge policy is configured to auto.

**Auto-Merge Stage**

- **Kind:** `tool`
- **Manifest:** `plugins/tool/merge/manifest.yaml`

## Manifest

```yaml
id: merge
name: Auto-Merge Stage
kind: tool
version: 0.1.0
description: |
  Auto-merge tool plugin (ADR-037 §4, I9-B / #1050, I9-C / #1051). When
  merge_policy: auto is active and gate-aggregator-result.json verdict is pass,
  merges via `gh pr merge --squash --auto`. When merge_policy: auto_unless_flagged,
  pr-delivery additionally requires review-report.json merge_readiness to be ready
  or advisory before delegating here; absent review-report is fail-closed (PR path).
  Falls back to pr_open_run when gate is absent or verdict != pass. Refuses on main/master.
  No LLM dependency — T0 tool stage (ADR-013).

hooks:
  run: merge_run
  cleanup: merge_cleanup

requires:
  core:
    - event-bus
    - state

provides:
  artifact_type: merge-result.json
  schema_version: 1

config:
  tier_default: T0

inputs:
  - id: gate_aggregator_result
    type: file
    path: "${artifact_dir}/gate-aggregator-result.json"
    source: stage:gate-aggregator
    required: false
  # #979 (EPIC #1277): the standard.yaml `review` stage was retired. Its
  # stage:review input dangled (no producing manifest) and tripped the
  # lint-contract data-dependency graph check. merge_run's ADR-001/#358
  # fail-closed guard still reads review.json BY PATH at runtime (absent →
  # route to the PR fallback path, which itself fail-closes) — behavior
  # unchanged; only the dead producer edge is removed from the contract graph.

outputs:
  - id: merge_result
    path: ${artifact_dir}/merge-result.json
    type: merge-result.json
    required: true
    primary: true
  - id: pr_url
    path: ${artifact_dir}/pr-url.txt
    type: pr-url.txt
    required: false

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
