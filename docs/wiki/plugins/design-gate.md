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
  issue #1218). The PRE-build mechanical structural gate for the design stage.
  C1..C5 are pure grep over design.md, with NO model call (ADR-037 §3 invariant).
  C6 (#1777) is the one check that runs anything: it executes each [guard] SPEC's
  assertion at the merge-base.

  Runs six structural checks and reports ALL violations in ONE pass (no
  whack-a-mole):
    C1 SCOPE           — design.md carries a non-empty ```scope block.
    C2 ACCEPTANCE      — the ```acceptance block is present + parseable.
    C3 CLASSIFIED      — every SPEC-n carries a [change] or [guard] classifier.
    C4 CHANGE-TESTFILE — if ≥1 [change] SPEC, TESTFILES is non-empty AND each
                         declared testfile exists on disk.
    C5 WIRING          — a WIRING: section is present ("none" ok); each concrete
                         path exists on disk.
    C6 GUARD-BASELINE  — every [guard] SPEC's tagged assertion HOLDS at the
                         merge-base. One that fails there is a mislabelled
                         [change] (#1777, ADR-036 §Amendment #1670).

  (The original C6, Level-1 tag-presence, was deleted by #1477 when build became
  the sole author of assertion bodies; #1777 reuses the free number.)

  C6 FAILS OPEN — no baseline, no worktree, a timeout, an unparseable baseline
  copy or an untagged guard (#1255) all SKIP, never fail. Because a silent skip
  is indistinguishable from a working check, design-gate-result.json records a
  `guard_precheck` block (declared / verified / failed / per-SPEC skip reason)
  and the feedback file states it in prose. The key is absent when a design
  declares no [guard] SPEC.

  C6 cannot save the FIRST build cycle: at the first design pass the branch has
  no commits and the assertion does not exist yet (build authors it). It earns
  its keep on the rewind, rejecting a re-submitted mislabel in one design turn
  instead of another full build cycle.

  verdict = pass IFF zero violations, else fail (verdict-in-artifact, ADR-040).
  Always returns rc=0; the verdict lives in design-gate-result.json and the
  design_verify_cycle's exit_when reads it. design-gate-feedback.md is written
  ONLY on fail and is wired back into design.prior_impact_feedback.

  Level-2's [change] half (negative-control / tautology) and Level-3
  (reachability) CANNOT shift left — they need a built assertion + baseline-vs-
  HEAD run — and remain at the post-build acceptance-gate (ADR-036). Level-2's
  [guard] half needs only a baseline run, which is why C6 can shift left at all;
  the acceptance-gate check remains the authority, C6 is an earlier net. This gate is repo-agnostic (ADR-042):
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
