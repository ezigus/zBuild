Looking at the existing wiki page, it doesn't conform to the required template structure — it's missing the NEWCOMER_OPENING prose, HOW_TO_USE, REFERENCE, and ADVANCED sections, and opens with bold structural labels instead of plain prose. I'll generate a conforming replacement.

# build

The build plugin is the implementation stage agent in a zBuild pipeline: it reads the plan produced by the plan stage and invokes the LLM to write the actual code changes. It produces a `diff.patch` and a `build-summary.json`; the diff is never applied here — the downstream test stage validates and applies it.

## How to use

Add `build` as a stage in your template's `flow:` to wire it into a delivery pipeline. It requires a `plan.json` input from a preceding `plan` stage and a `scope-manifest.md` from `intake`. A minimal wiring in `simple.yaml` looks like:

```yaml
flow:
  - stage: intake
  - stage: plan
  - stage: build
  - stage: test
```

Inside a cycle (e.g. `build_test_cycle` or `build_review_cycle`) the orchestrator exports `ZBUILD_CYCLE_FEEDBACK_DIR`, which the build plugin reads automatically to inject prior test-assessment, review, acceptance-gate, or gate-aggregator feedback into the LLM prompt on subsequent iterations. No extra template configuration is needed for feedback wiring once the cycle block declares the edges.

## Reference

**Kind:** `agent` — the build plugin runs a full `route_to_model_loop` invocation; it consumes multiple turns until the LLM signals completion or the iteration cap is hit.

**Manifest:** `plugins/agent/build/manifest.yaml` · version `0.1.0` · `tier_default: T2`

**Hooks**

| Hook | Function |
|------|----------|
| `init` | `build_stage_init` |
| `run` | `build_stage_run` |
| `finalize` | `build_stage_finalize` |
| `cleanup` | `build_stage_cleanup` |

**Requires**

| Layer | Dependencies |
|-------|-------------|
| `core` | `redaction`, `event-bus`, `state`, `router` |
| `plugins` | _(none)_ |

**Inputs**

| ID | Type | Source | Required | Notes |
|----|------|--------|----------|-------|
| `scope_manifest` | file | `stage:intake` | yes | |
| `intake_baseline_ref` | text | `stage:intake` (`intake-baseline-ref.txt`) | no | Opt-out via `ZBUILD_INTAKE_SKIP_BRANCH` |
| `plan` | file | `stage:plan` (`plan.json`) | yes | |
| `prior_test_assessment` | text/markdown | `cycle_feedback` | no | Omitted when empty; also carries `test_failures_summary` in `simple.yaml` |
| `prior_review_feedback` | text/markdown | `cycle_feedback` | no | Fed by `build_review_cycle` review edge |
| `prior_acceptance_feedback` | text/json | `cycle_feedback` | no | Surfaces `untagged_spec:<id>` failures only |
| `prior_gate_feedback` | text/markdown | `cycle_feedback` | no | Consolidated gate-aggregator feedback (ADR-040) |
| `design` | file | `stage:design` (`design.md`) | no | When present, a ` ```scope ` block overrides `plan.json files[]` |

**Outputs**

| ID | Path | Type | Required | Notes |
|----|------|------|----------|-------|
| `diff_patch` | `${artifact_dir}/diff.patch` | patch | yes | Working-tree diff captured after the agent loop; never applied here |
| `build_summary` | `${artifact_dir}/build-summary.json` | build-summary.json | yes | Primary output; `.verdict` drives the stage indicator (`pass` \| `scope_violation`) |

**Capabilities** (ADR-047 §4): `produces_commits: true`, `empty_diff_legitimate: true`

**State**

- Persisted: `last_files_changed`, `last_lines_added`
- Reconstructed: `plan_json`

## Advanced

_Newcomers can skip this section._

**ADR-018 Pattern 2 — agent-loop with derived diff.** The build plugin follows Pattern 2: it delegates to `route_to_model_loop`, then captures the resulting working-tree state with `git diff HEAD` after the loop returns. The diff is written to `diff.patch`; it is never staged or committed inside this plugin. The test stage owns application and validation.

**Prompt framing (three-section structure, #571 v2).** Every LLM invocation sees: (1) ORIGINAL TASK — the issue goal and rendered `plan.json`; (2) INSTRUCTIONS — scope, loop, and sentinel rules; (3) CURRENT ITERATION FEEDBACK — empty on iter 1, populated from `prior_test_assessment`, `prior_review_feedback`, `prior_acceptance_feedback`, and/or `prior_gate_feedback` on subsequent iters. Feedback text is stripped of stage-io banners and ANSI codes via `_zbuild_sanitize_for_llm` before injection (#721).

**Scope sources and priority.** Scope is resolved in this order: (1) `design.md` ` ```scope ` block (ADR-018, #754) when present — emits `build.scope_injected`; (2) `plan.json files[]` (falling back to `steps[].files[]` for the legacy plan shape); (3) paths appended from `ZBUILD_SCOPE_EXPANSION_GRANT` when a prior-iter scope-expansion request was auto-granted (ADR-030, #840).

**Acceptance-charter injection (ADR-031, #866).** When `design.md` contains a structured acceptance block, `acceptance_list_spec_ids` enumerates the SPEC ids and the prompt mandates that the build tag every one. This is the Layer 1 mechanism; Layer 2 (ADR-036, #951) closes the loop by feeding untagged spec failures back via `prior_acceptance_feedback` on the next cycle iter.

**Intake baseline ref (#663, ADR-020).** When `intake-baseline-ref.txt` is present, the build agent constrains diff generation to changes since that ref — preventing the LLM from touching pre-existing untracked files (materialized via `_build_load_preexisting_untracked` into a sorted temp file for portable `grep -Fxq` membership lookup).

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the plugin contract._
