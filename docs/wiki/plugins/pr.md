# pr

**PR Open Stage**

- **Kind:** `tool`
- **Manifest:** `plugins/tool/pr-open/manifest.yaml`

## Manifest

```yaml
id: pr
name: PR Open Stage
kind: tool
version: 0.1.0
description: |
  Opens a draft pull request via `gh pr create --draft`. Reads the review.json
  artifact from the prior review stage and refuses to open if verdict == "block".
  Also refuses if the current branch is main or master. Always produces a draft PR.
  No LLM dependency — T0 tool stage (ADR-013).

hooks:
  init: pr_open_init
  run: pr_open_run
  finalize: pr_open_finalize
  cleanup: pr_open_cleanup

requires:
  core:
    - event-bus
    - state

provides:
  # Canonical artifact per ADR-013: pr-url.txt.
  # The plugin also writes pr-result.json (richer status payload, listed in
  # outputs[] below); both are written on success. See ADR-013 Implementation
  # Notes for the canonical vs. secondary artifact convention.
  artifact_type: pr-url.txt
  schema_version: 1

config:
  tier_default: T0
  always_draft: true

inputs:
  # #979 (EPIC #1277): the standard.yaml `review` stage (which produced the
  # blocking review.json) was retired, so its stage:review input is dropped —
  # it dangled (no producing manifest) and tripped the lint-contract graph check.
  # The advisory review-aggregator (review-report.json, below) is now the only
  # review data source. plugin.sh still reads review.json BY PATH if present (a
  # per-repo overlay could still emit one) and falls back to advisory mode when
  # it is absent — behavior unchanged; only the dead stage edge is removed.
  - id: review_report
    type: file
    path: "${artifact_dir}/review-report.json"
    source: stage:review-aggregator
    required: false

outputs:
  - id: pr_url
    path: ${artifact_dir}/pr-url.txt
    type: pr-url.txt
    required: true
    # ADR-020 amendment (#507): canonical primary (non-JSON). Indicator
    # falls back to rc-only: present == pass.
    primary: true
  - id: pr_result
    path: ${artifact_dir}/pr-result.json
    type: pr-result.json
    required: true

state:
  persisted: [last_pr_url, last_pr_number]
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
