# impact

The impact plugin is an adversarial consequence-finder that sits inside the `design_impact_cycle`: it reads the exhaustive scope block that the design stage produced and flags any files the change touches, invalidates, or requires updating that design missed. Teams use it to catch scope gaps before build begins, preventing test failures caused by undeclared file dependencies.

## How to use

Add `impact` as a stage in your pipeline template's `flow:` after the `design` stage and before `build`. The plugin wires automatically to the `design` and `plan` stages through their declared outputs.

```yaml
flow:
  - stage: design
  - stage: impact
  - stage: build
```

`impact` is a member of `design_impact_cycle`. When its verdict is `incomplete`, `impact_feedback.md` is fed back to `design.prior_impact_feedback` and the cycle repeats. No manual wiring is needed if the cycle is declared in your template.

## Reference

**Kind:** `agent`
**Role:** `impact_analyzer`
**Manifest:** `plugins/agent/impact/manifest.yaml`
**Version:** 0.1.0
**Tier default:** T2 (Sonnet)

### Hooks

| Hook       | Function         |
|------------|-----------------|
| `run`      | `impact_run`     |
| `cleanup`  | `impact_cleanup` |

### Requires

| Scope   | Dependencies                          |
|---------|---------------------------------------|
| `core`  | `redaction`, `event-bus`, `state`, `router` |
| plugins | _(none)_                              |

### Inputs

| ID              | Type   | Source          | Required |
|-----------------|--------|-----------------|----------|
| `scope_manifest`| file   | `stage:intake`  | yes      |
| `design`        | file   | `stage:design`  | yes      |
| `plan`          | file   | `stage:plan`    | no       |

`design` is the primary source — the plugin reads its ` ```scope ` block. `plan` is secondary and used only by the deterministic shape-change prefilter.

### Outputs

| ID                 | Path                              | Type         | Required |
|--------------------|-----------------------------------|--------------|----------|
| `impact`           | `${artifact_dir}/impact.json`     | `impact.json`| yes (primary) |
| `impact_feedback_md` | `${artifact_dir}/impact_feedback.md` | markdown | no       |

### Output schema (`impact.json`)

```json
{
  "schema_version": 1,
  "verdict": "complete" | "incomplete",
  "missing": [
    {
      "step_id": "<plan step id>",
      "files_to_add": ["<repo-relative path>"],
      "reason": "<why these files need to be in scope>"
    }
  ],
  "impact_feedback_md": "<markdown report fed back to design on next cycle iter>"
}
```

### State

| Key           | Lifecycle   |
|---------------|-------------|
| `last_verdict`| persisted   |

## Advanced

_Newcomers can skip this section._

**Tier rationale (ADR-003, #960, #1242).** Impact is the most tool-heavy agentic stage — up to 45 tool turns of `Read` and `Grep` across the design scope and repo. T1 (Haiku) blew past the then-180 s router timeout when design scopes grew (rc=124, run 20260619082915-41231). T2 is mandated in `manifest.yaml`; the router wall-clock budget is 600 s (matching `design`).

**Deterministic prefilter (#781).** Before the LLM runs, `scripts/lib/impact-prefilter.sh` applies the CLAUDE.md "Test scope discovery" rule: it greps `tests/` for numeric shape values derived from `plan.json` and scans `tests/golden/**`. Results are injected into the prompt as `CANDIDATE GAPS`. Entries with `source=shape-change-golden` are mandatory — the post-LLM bash merge enforces them. Entries with `source=shape-change-numeric` are advisory — the LLM may drop them with a one-line reason.

**Prompt overrides (ADR-032, #855).** Per-repo operator overlays are appended to the prompt file after the shipped charter via `append_prompt_override`. The overlay can never precede or weaken the output contract. ADR-043 delegates redaction to the router, which covers the overlay.

**Hallucination guard (#911).** The LLM must verify file existence with `Read` or `Grep` before listing any path in `missing[].files_to_add`. Non-existent paths are stripped by a post-LLM bash merge step to prevent the design stage from chasing phantom gaps.

**Budget discipline.** The agent prompt enforces a hard stop: emit a verdict before the tool-call budget runs out. A partial `incomplete` verdict with known gaps is preferable to running out of turns and returning nothing.

**Cycle wiring.** `impact_feedback_md` is consumed by the design stage as `prior_impact_feedback` on the next iteration. The cycle is bounded; a stuck-detector (A→B→A pattern) and a kill-switch prevent infinite loops. See ADR-040 §5 and [[design_impact_cycle]] for the convergence contract.

_See docs/DOC-STYLE.md for the full prose standard._
