# review-report

The review-report plugin fans multiple review lenses out as independent LLM calls and assembles their outputs into a combined merge-readiness report.

**Review Report (multi-lens, advisory)**

- **Kind:** `agent`
- **Role:** `review_report`
- **Manifest:** `plugins/agent/review-report/manifest.yaml`

## Manifest

```yaml
id: review-report
name: Review Report (multi-lens, advisory)
kind: agent
version: 0.1.0
description: |
  Evidence-fed multi-lens merge-readiness report (ADR-038, EPIC #966 I6).
  Fans N lenses out as N independent LLM calls over the change bundle, then
  aggregates + de-dupes findings by file + category + proximity into one
  advisory merge-readiness report (ready|advisory|needs_attention). Advisory
  only: it emits findings + severities + rationale, never recommends a merge
  action and never gates the pipeline. Posts the report to the PR as a comment
  when ZBUILD_PR_NUMBER is set (fail-soft).

  Bound to the single `review` stage of simple.yaml via provides.role
  (resolver.sh) — NOT a new flow stage. standard.yaml is unaffected (its
  `review` stage still resolves to the legacy `review` plugin).

hooks:
  init: review_report_init
  run: review_report_run
  finalize: review_report_finalize

requires:
  core:
    - redaction
    - event-bus
    - state
    - router
  plugins: []

# Bound by ROLE (resolver.sh reads provides.role). Deliberately NO
# provides.artifact_type: declaring it makes contracts.sh synthesize a BLOCKING
# contract-violated findings.json on a miss — this stage is advisory, so we opt
# out of that machinery. The plugin still always writes review-report.json first.
provides:
  role: review_report
  schema_version: 1

config:
  tier_default: T2
  # I6 fixed lens roster (the full cq+persona roster is #974). Each lens is a
  # SEPARATE LLM call (not one prompt with N sections — the cq-cycle trap
  # ADR-038 §2 rejects). For I6 every lens shares the change bundle as
  # placeholder evidence; #973 feeds each lens distinct mechanical evidence.
  lenses:
    - correctness
    - security
    - test-coverage
    - design-conformance
    - integration
    - error-handling
    - performance
    - edge-case
    - architecture
    - red-team
    - maintainability

inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
  - id: plan
    type: file
    path: "${artifact_dir}/plan.json"
    source: stage:plan
    required: false
  - id: diff_patch
    type: file
    path: "${artifact_dir}/diff.patch"
    source: stage:build
    required: true
  - id: intake_goal
    type: file
    path: "${state_dir}/intake.md"
    source: stage:intake
    required: false

outputs:
  # FIRST entry — always written; keeps the stage green without opting into the
  # blocking artifact-contract (no provides.artifact_type above).
  - id: review_report
    path: "${artifact_dir}/review-report.json"
    type: review-report.json
    required: true
    primary: true
  - id: review_report_md
    path: "${artifact_dir}/review-report.md"
    type: markdown
    required: false

state:
  persisted:
    - last_merge_readiness
    - last_lens_count
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
