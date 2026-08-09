# lint-gate

The lint-gate plugin is a deterministic, LLM-free gate that reads lint results from the shared test framework and fails the stage when lint errors are present.

**Lint Read-out Gate**

- **Kind:** `tool`
- **Role:** `lint_gate`
- **Manifest:** `plugins/tool/lint-gate/manifest.yaml`

## Manifest

```yaml
id: lint-gate
name: Lint Read-out Gate
kind: tool
# ADR-040 §5: convergence marker. `gate` = mechanical must-pass gate (dormant in
# simple.yaml's roster today; marker keeps it correct if/when reused).
convergence: gate
version: 0.1.0
description: |
  Deterministic, LLM-free T0 read-out gate (ADR-040, issue #1135, EPIC #1129).
  A THIN read-out gate: it consumes the SHARED test-framework result
  (test-results.json, produced by the test stage / #1133) and NEVER re-runs the
  linter. Reads the `lint` block and maps its status to a verdict:
    - lint.status skipped  → verdict=skip
    - lint.status fail     → verdict=fail
    - lint.status pass     → verdict=pass
  When test-results.json is absent or carries no `lint` block → verdict=skip.
  Always returns rc=0; the verdict lives in lint-result.json (ADR-040
  verdict-in-artifact convention, mirrors shape-floor).
  ADR-037 §3 invariant: T0 tool stages contain no LLM/router calls.

hooks:
  run: lint_gate_run
  cleanup: lint_gate_cleanup

requires:
  core:
    - event-bus
    - state
  plugins: []

provides:
  role: lint_gate
  artifact_type: lint-result.json
  schema_version: 1

config:
  tier_default: T0

inputs:
  - id: test_results
    type: file
    path: "${artifact_dir}/test-results.json"
    source: stage:test
    required: false

outputs:
  - id: lint_result
    path: "${artifact_dir}/lint-result.json"
    type: lint-result.json
    required: true
    primary: true

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
