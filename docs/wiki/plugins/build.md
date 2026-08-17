# build

The build plugin is the implementation stage of a zBuild pipeline: it reads the structured plan produced by the plan stage, invokes the LLM agent, and writes a `diff.patch` capturing all file changes. The patch is never applied inside this plugin — the downstream test stage applies and validates it, so a failed test cycle routes back to build with fresh feedback rather than leaving the working tree in a broken state.

## How to use

Add `build` to your template's `flow:` after `plan` (and optionally `design`):

```yaml
flow:
  - plan
  - build
  - test
```

For iterative refinement, wrap it in a `build_test_cycle` so test failures are automatically fed back into the next build iteration:

```yaml
flow:
  - plan
  - build_test_cycle:
      stages: [build, test]
      max_iterations: 5
```

The cycle orchestrator exports `ZBUILD_CYCLE_FEEDBACK_DIR`; build reads feedback files from that directory on iterations 2 and beyond.

## Reference

**Manifest:** `plugins/agent/build/manifest.yaml`

```yaml
id: build
name: Build Stage
kind: agent
version: 0.1.0
description: |
  Build stage agent. Reads the plan.json artifact produced by the plan stage
  and invokes the LLM (T2) to produce a diff.patch and build-summary.json.
  The diff.patch is NEVER applied inside this plugin — it is written as an
  artifact for the downstream test stage to validate and apply.

hooks:
  run: build_stage_run
  cleanup: build_stage_cleanup

requires:
  core:
    - redaction
    - event-bus
    - state
    - router
  plugins: []

provides:
  artifact_type: build-summary.json
  role: builder
  schema_version: 1

config:
  tier_default: T2

inputs:
  - id: scope_manifest
    type: file
    source: stage:intake
    required: true
  - id: intake_baseline_ref
    type: text
    path: "${state_dir}/intake-baseline-ref.txt"
    source: stage:intake
    required: false
  - id: plan
    type: file
    path: "${artifact_dir}/plan.json"
    source: stage:plan
    required: true
  - id: prior_test_assessment
    type: text/markdown
    path: "${cycle_feedback_dir}/prior_test_assessment.txt"
    source: cycle_feedback
    required: false
  - id: prior_review_feedback
    type: text/markdown
    path: "${cycle_feedback_dir}/prior_review_feedback.txt"
    source: cycle_feedback
    required: false
  - id: prior_acceptance_feedback
    type: text/json
    path: "${cycle_feedback_dir}/prior_acceptance_feedback.txt"
    source: cycle_feedback
    required: false
  - id: prior_gate_feedback
    type: text/markdown
    path: "${cycle_feedback_dir}/prior_gate_feedback.txt"
    source: cycle_feedback
    required: false
  - id: design
    type: file
    path: "${artifact_dir}/design.md"
    source: stage:design
    required: false

outputs:
  - id: diff_patch
    path: "${artifact_dir}/diff.patch"
    type: patch
    required: true
  - id: build_summary
    path: "${artifact_dir}/build-summary.json"
    type: build-summary.json
    required: true
    primary: true

state:
  persisted: [last_files_changed, last_lines_added]
  reconstructed: [plan_json]

capabilities:
  produces_commits: true
  empty_diff_legitimate: true
```

### Inputs at a glance

All `cycle_feedback` inputs are optional: when the file is absent or empty, the corresponding prompt section is omitted entirely. Multiple feedback channels can coexist in the same iteration.

| ID | Required | Purpose |
|----|----------|---------|
| `scope_manifest` | yes | In-scope file list from intake |
| `plan` | yes | Structured implementation plan |
| `design` | no | `design.md` scope block overrides `plan.json files[]` when present |
| `prior_test_assessment` | no | Test-failure detail from the previous cycle iteration |
| `prior_review_feedback` | no | Review findings from `build_review_cycle` outer loop |
| `prior_acceptance_feedback` | no | Untagged SPEC ids from the prior acceptance-gate run |
| `prior_gate_feedback` | no | Consolidated gate-aggregator summary (replaces per-gate edges after ADR-040) |
| `intake_baseline_ref` | no | Baseline ref for diff-constraint when intake branch capture is active |

## Advanced

_Newcomers can skip this section._

**Agent-loop shape (ADR-013, ADR-018 Pattern 2):** Build is classified as a T2 agent stage. The LLM sees a three-section framed prompt on every iteration: (1) ORIGINAL TASK — immutable issue goal and rendered `plan.json`; (2) INSTRUCTIONS — scope rules, loop contract, sentinel; (3) CURRENT ITERATION FEEDBACK — empty on iteration 1, populated by any non-empty feedback inputs on subsequent iterations. The working-tree diff is captured via `git diff HEAD` after the loop exits; the plugin never applies the patch itself.

**Feedback sanitization (issue #721):** All feedback bodies — `prior_test_assessment`, `prior_review_feedback`, and `prior_gate_feedback` — pass through `_zbuild_sanitize_for_llm` before being spliced into the prompt. These files are captured pipeline output and carry stage-io banners and ANSI codes that degrade LLM signal.

**Feedback channel history:**
- `prior_test_assessment` — original test→build wire (ADR-020/021/022, issue #571)
- `prior_review_feedback` — outer review→build wire (ADR-026, Wave 18-B, issue #707)
- `prior_acceptance_feedback` — acceptance-gate SPEC gap ids (ADR-036, issue #951)
- `prior_gate_feedback` — single gate-aggregator channel replacing per-gate edges after the ADR-040 roster cutover (B2)

**Cross-run seeding (ADR-050, issue #1581):** When a prior run of the same issue left a `build-summary.json` that is restored onto the runner, a sanitized summary is appended to the prompt after the composed body — mirroring design's prior-work injection — so the new run continues rather than restarts.

**Per-repo prompt overrides (ADR-032, issue #855):** A per-repo override block is appended after the shipped charter, so operator overlays can never precede or weaken the core contract. Redaction is delegated to `route_to_model_loop` (ADR-043), which applies `core/redaction` to every iteration including the override text.

**Capability flags (ADR-047 §4):** `produces_commits: true` and `empty_diff_legitimate: true` replace hardcoded `[[ "$_cm" == "build" ]]` guards in the orchestrator with manifest-driven checks.

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the contract._
