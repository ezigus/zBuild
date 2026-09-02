# spec-coverage

The spec-coverage plugin judges whether the design's acceptance block covers what the ISSUE asked for — the one link in the chain above the SPEC, where design is the only reader of the issue.

**Spec Coverage**

- **Kind:** `agent`
- **Role:** `spec_coverage`
- **Manifest:** `plugins/agent/spec-coverage/manifest.yaml`

## Manifest

```yaml
id: spec-coverage
name: Spec Coverage
kind: agent
# ADR-040 §5 as amended by #2040: a model-judged stage MAY gate when the standard
# it judges against is one the judged party cannot re-author. The standard here
# is the ISSUE, and design cannot edit it — the only way to converge is to
# actually cover it. `intake_goal` is produced by intake, outside this cycle,
# which is what the load-time check requires.
convergence: gate
version: 0.1.0
description: |
  Judges whether the design's acceptance block covers what the ISSUE asked for.

  Design is the single reader of the issue: it reads the issue and writes the
  SPECs, and nothing else ever confirms the SPECs are a faithful statement of
  the ask. A design that under-scopes or misreads produces a contract every
  downstream check satisfies perfectly — green all the way down, and not what
  was asked for.

  Runs inside design_verify_cycle, so a finding reaches design itself on the
  next iteration rather than after the loop has exited.

  Checkboxes, where an issue has them, are the strongest evidence of intent and
  each must map to a SPEC. Where it has none, the requirement is read out of the
  prose — most issues are prose, which is why tracing checkboxes alone (#1683's
  original framing) could never be the whole check.

hooks:
  run: spec_coverage_run

requires:
  core:
    - redaction
    - event-bus
    - router

provides:
  role: spec_coverage
  result_contract: 2
  events:
    - spec_coverage.judged
    - spec_coverage.unreadable_issue
    - spec_coverage.result.write_failed

config:
  valid_verdicts:
    - covered
    - uncovered
    - unreadable
  tier_default: T2

inputs:
  # The REFERENCE: produced by intake, outside this cycle, so design cannot
  # re-author the standard it is judged against (ADR-040 §5, #2040).
  - id: intake_goal
    required: true
  # The artifact under review. A comparison needs both sides.
  - id: design
    required: true

outputs:
  - id: spec_coverage_result
    path: "${artifact_dir}/spec-coverage-result.json"
    type: spec-coverage-result.json@1
    format: json
    required: true
    primary: true
  # ADR-055 §9: this stage's statement of what it DID.
  - id: spec_coverage_summary
    path: "${artifact_dir}/spec-coverage-summary.md"
    type: spec-coverage-summary.md@1
    format: markdown
    required: true
    summary: true
```
