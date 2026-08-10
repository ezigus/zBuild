# mutation-gate

The mutation-gate plugin is a deterministic, LLM-free gate that reads mutation-test results and fails the stage when the mutation score falls below the configured floor.

**Mutation Read-out Gate**

- **Kind:** `tool`
- **Role:** `mutation_gate`
- **Manifest:** `plugins/tool/mutation-gate/manifest.yaml`

## Manifest

```yaml
id: mutation-gate
name: Mutation Read-out Gate
kind: tool
# ADR-040 §5: convergence marker. `gate` = mechanical must-pass gate (dormant in
# simple.yaml's roster today; marker keeps it correct if/when reused).
convergence: gate
version: 0.1.0
description: |
  Deterministic, LLM-free T0 read-out gate (ADR-040, issue #1135, EPIC #1129).
  A THIN read-out gate: it consumes the SHARED test-framework result
  (test-results.json, produced by the test stage / #1133) and NEVER re-runs the
  mutation harness. Reads the `mutation` block and maps it to a verdict:
    - mutation.status skipped         → verdict=skip
    - score N/M parsed, N < floor     → verdict=fail
    - otherwise                       → verdict=pass
  Floor preference: the `floor` recorded in test-results.json wins; otherwise
  ZBUILD_MUTATION_FLOOR (default 0). When test-results.json is absent or carries
  no `mutation` block → verdict=skip.
  Always returns rc=0; the verdict lives in mutation-result.json (ADR-040
  verdict-in-artifact convention, mirrors shape-floor).
  ADR-037 §3 invariant: T0 tool stages contain no LLM/router calls.

hooks:
  run: mutation_gate_run
  cleanup: mutation_gate_cleanup

requires:
  core:
    - event-bus
    - state
  plugins: []

provides:
  role: mutation_gate
  artifact_type: mutation-result.json
  schema_version: 1

config:
  tier_default: T0
  mutation_floor: 0

inputs:
  - id: test_results
    type: file
    path: "${artifact_dir}/test-results.json"
    source: stage:test
    required: false

outputs:
  - id: mutation_result
    path: "${artifact_dir}/mutation-result.json"
    type: mutation-result.json
    required: true
    primary: true

state:
  persisted: []
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
