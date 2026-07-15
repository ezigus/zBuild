# design

The design plugin is the pipeline's first AI-authored stage: it reads the plan produced by the plan stage and asks an LLM to write an ADR-style design document that enumerates every file the change will touch. If you are wiring up a new issue, this is the stage that turns a goal into a concrete, testable scope before a single line of implementation is written.

## How to use

Add the plugin to your template's `flow:` as a stage between `plan` and `build`:

```yaml
flow:
  - stage: intake
  - stage: plan
  - stage: design   # <-- this plugin
  - stage: build
  - stage: test
```

No extra configuration is required. The plugin reads `plan.json` from the previous stage's artifacts and writes `design.md` to `${artifact_dir}/design.md`. The build stage then reads the `scope` block from that file to determine which files it may touch.

## Reference

**Kind:** `agent` — runs the LLM via the T2 router inside an agent loop; produces one file artifact.

**Manifest:** `plugins/agent/design/manifest.yaml`

**Hooks**

| Hook | Function |
|---|---|
| `init` | `design_stage_init` |
| `run` | `design_stage_run` |
| `finalize` | `design_stage_finalize` |
| `cleanup` | `design_stage_cleanup` |

**Requires**

| Kind | Dependency |
|---|---|
| core | `redaction`, `event-bus`, `state`, `router` |
| plugins | _(none)_ |

**Inputs**

| ID | Type | Source | Required |
|---|---|---|---|
| `scope_manifest` | file | `stage:intake` | yes |
| `plan` | file (`plan.json`) | `stage:plan` | yes |
| `prior_impact_feedback` | file | `cycle_feedback` | no |
| `prior_design` | file | `cycle_feedback` | no |
| `prior_gate_feedback` | file | `artifacts` (`design-feedback.md`) | no |

**Outputs**

| ID | Path | Type | Primary |
|---|---|---|---|
| `design` | `${artifact_dir}/design.md` | `text/markdown` | yes |

**Tier default:** T2

**Version:** 0.1.0

**What `design.md` must contain**

The LLM is required to produce three fenced blocks in every `design.md`:

1. An architectural decision summary (goal, context, decision).
2. A ` ```scope ` block — one repo-relative path per line — that is an **exhaustive** enumeration of every file the change touches, including tests that pin a value being changed, config/schema/golden files, ADRs, and every source file that references a renamed or added symbol. The scope block is the authoritative source consumed by the build stage; files not listed here cannot be modified downstream.
3. An ` ```acceptance ` block with stable `SPEC-n` ids, classification tags (`[change]` or `[guard]`), a `WIRING:` field, and a `TESTFILES:` section listing the test files that will carry the `[SPEC-n]`-tagged assertions.

## Advanced

_Newcomers can skip this section._

**ADR references**

- **ADR-013** — T2 tier assignment and `blocking: true` semantics.
- **ADR-018 Pattern 2** — agent-loop, single-file artifact shape (reclassified from Pattern 1 in ADR-018 Amendment v4, issue #816).
- **ADR-036** — acceptance-gate SPEC tagging rules: every `SPEC-n[change]` assertion must fail at the merge-base baseline; the gate refuses a build where any SPEC-n has no `[SPEC-n]`-tagged assertion in its TESTFILES.
- **ADR-045 / ADR-046** — `route_back` rewind: when the gate-aggregator emits `verdict=route_design`, it writes `design-feedback.md` to the shared artifacts directory. On the next design pass the plugin reads this file via `_design_read_prior_gate_feedback` and re-authors the SPEC block. This path is keyed on **file presence**, not the `ZBUILD_CYCLE_ITER` counter.

**Cycle feedback edges**

The plugin carries three distinct feedback paths for multi-iteration cycles:

- `prior_impact_feedback` — impact's gap report wired back via `ZBUILD_CYCLE_FEEDBACK_DIR` so design can expand its scope when impact finds missed consequences (active on `ZBUILD_CYCLE_ITER ≥ 2`).
- `prior_design` — design's own previous output, letting iter N+1 refine rather than re-create (the #773 lesson; same iter guard).
- `prior_gate_feedback` — gate-aggregator feedback arriving via a `route_back` rewind from the `build_test_cycle`; this crosses cycle boundaries and is therefore keyed on file presence, not the iteration counter.

**Verdict sidecar**

At the start of every run the plugin removes `${artifact_dir}/design-verdict.json`. This ensures a stale `did_not_finish` verdict from a prior timeout can never leak into a later iteration that produced a valid `design.md`. The sidecar is written only on a router timeout; `verdict.sh` reads it as design's raw verdict for the cycle.

**Scope enumeration obligation**

A scope block that merely echoes `plan.json`'s `files[]` is a contract violation. The LLM is required to actively search the repository (Read/Grep/Glob) and include every exhaustive enumeration site — every place that lists the current membership of a set being grown — because breakage from adding a new member is a *missing* line, not a stale value, and therefore invisible to a grep for the old value.

_See [[Pipeline-and-Stages]] for how this plugin is dispatched, and [[Writing-Plugins]] for the plugin contract._
