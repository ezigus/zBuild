# output-github-comment

The output-github-comment plugin is the final pipeline stage, aggregating findings from all prior analysis stages and posting a formatted report as a GitHub issue comment.

**Output — GitHub Issue Comment**

- **Kind:** `tool`
- **Role:** `output`
- **Manifest:** `plugins/tool/output-github-comment/manifest.yaml`

## Manifest

```yaml
id: output-github-comment
name: Output — GitHub Issue Comment
kind: tool
version: 0.1.0
description: |
  Final pipeline stage. Aggregates findings.json artifacts from all prior
  analysis stages, renders a markdown severity table, and posts to the
  GitHub issue (or writes a local report if no issue number is set).
  Output destination abstraction (stdout, PR comment, check run) is
  tracked in #213.

hooks:
  init: output_init
  run: output_run
  finalize: output_finalize

requires:
  core:
    - event-bus
    - state

provides:
  artifact_type: [report.md]
  role: output

config:
  severity_order: [critical, high, medium, low, info]
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
