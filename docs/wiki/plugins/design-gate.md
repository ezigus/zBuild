# design-gate

The design-gate plugin is a deterministic, LLM-free structural gate that validates the design output before the build stage begins.

**Design Gate Stage**

- **Kind:** `tool`
- **Role:** `design_gate`
- **Manifest:** `plugins/tool/design-gate/manifest.yaml`

## Manifest

```yaml
id: design-gate
name: Design Gate Stage
kind: tool
# ADR-046 §/ADR-040 §5: convergence marker. `gate` = mechanical must-pass gate.
# The design_verify_cycle's exit_when binds this member directly (design-gate is
# both a cycle member AND convergence:gate — the typed-aggregator preflight
# rule (A) is satisfied without a separate aggregator; there is a single gate).
convergence: gate
version: 0.1.0
description: |
  Deterministic, LLM-free T0 tool stage (ADR-046, ADR-037 §1/§3, EPIC #1216
  issue #1218). The PRE-build mechanical structural gate for the design stage:
  pure grep over design.md (structural checks C1..C5), with NO
  baseline run and NO model call (ADR-037 §3 invariant).

  Runs five structural checks and reports ALL violations in ONE pass (no
  whack-a-mole):
    C1 SCOPE           — design.md carries a non-empty ```scope block.
    C2 ACCEPTANCE      — the ```acceptance block is present + parseable.
    C3 STATUS          — every SPEC-n carries a status: [code], [no-code] or
                         [done] (the old [change] reads as code). An unknown
                         tag, or the retired [guard], is rejected. A [done]
                         SPEC names evidence after ` evidence: ` — repo-relative
                         paths (or path:N) that exist, N within the file
                         (#2304, ADR-069).
    C4 CODE-TESTFILE   — each [code] SPEC declares ≥1 testfile (existence is
                         checked later, by the acceptance gate, #1649).
    C5 WIRING          — a WIRING: section is present ("none" ok); each concrete
                         path exists on disk.
  (C6, the [guard] baseline pre-check, was removed with [guard] — ADR-069.)

  verdict = pass IFF zero violations, else fail (verdict-in-artifact, ADR-040).
  Always returns rc=0; the verdict lives in design-gate-result.json and the
  design_verify_cycle's exit_when reads it. design-gate-feedback.md is written
  on every terminal verdict (ADR-055 §9) and wired back into design.prior_impact_feedback.

  Level-2 (negative-control / tautology) and Level-3 (reachability) CANNOT shift
  left — they need a built assertion + baseline-vs-HEAD run — and remain at the
  post-build acceptance-gate (ADR-036). This gate is repo-agnostic (ADR-042):
  generic grep over the contract, no plugin/lang/path assumptions.

hooks:
  run: design_gate_run
  cleanup: design_gate_cleanup

requires:
  core:
    - event-bus
    - state
  plugins: []

provides:
  role: design_gate
  primary: true
  artifact_type: design-gate-result.json
  schema_version: 1

config:
  tier_default: T0

inputs:
  - id: design
    type: file
    path: "${artifact_dir}/design.md"
    source: stage:design
    required: true

outputs:
  - id: design_gate_result
    path: "${artifact_dir}/design-gate-result.json"
    type: design-gate-result.json
    required: true
    primary: true
  # Written ONLY on verdict=fail (all violations, actionable). required:false —
  # absent on a passing gate (missing == empty). Wired by simple.yaml's
  # design_verify_cycle as the design-gate → design (prior_impact_feedback) edge.
  - id: design_gate_feedback
    path: "${artifact_dir}/design-gate-feedback.md"
    type: markdown
    required: false

state:
  persisted: [last_verdict]
  reconstructed: []
```

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
