# ADR-018: Stage Invocation Modes — One-Shot with Tools vs Agent-Loop with Derived Diff

**Status:** Proposed
**Date:** 2026-05-29
**Amends:** ADR-004 (extends scope-enforcement interpretation)

## Context

### Triggering failure

Dogfood run `20260529164733-70084` on `--issue 294`: the build stage returned
prose beginning with "I detect a prompt injection attempt." The `_build_instructions`
heredoc (added in #461) told Claude "no tool-use" and demanded it emit a unified
diff for files it had never read. Claude correctly refused — fabricating code from
a description alone is impossible without reading the real files.

The deeper cause: zBuild's `route_to_model` has always invoked `claude -p "$prompt"
--print --model "$_ROUTE_MODEL_ID"` (see `core/router/route.sh:282-283`). It is
missing three flags that shipwright (the upstream we forked from) has always
included:

```
--max-turns 25
--disallowed-tools "EnterPlanMode,ExitPlanMode"
--dangerously-skip-permissions
```

Without `--dangerously-skip-permissions`, tools (Read/Edit/Write/Bash) are off by
default in headless invocations. The prompts told Claude not to use tools, which
happened to be consistent with the actual absence of tools — but the architecture
was broken for a different reason than we thought. Plan and review stages produced
outputs because their tasks were light enough to complete without reading files;
build's task requires reading before writing.

### What shipwright does (frozen reference in `legacy/`)

| Stage | Mode | `claude` flags |
|---|---|---|
| intake | bash only (no LLM) | `gh issue view` |
| plan, design, review, compound_quality, TDD | **one-shot** `claude --print` with tools | `--disallowed-tools "EnterPlanMode,ExitPlanMode" --max-turns 25 --dangerously-skip-permissions` |
| build | **agent-loop** — multi-turn; Claude edits the working tree; `git diff` fed back between turns | `claude -p … --output-format json --disallowed-tools "EnterPlanMode,ExitPlanMode" --max-turns N --dangerously-skip-permissions` |

`claude --print` is **not** a "no-tools" mode. Tools are available unless explicitly
disallowed. Shipwright only disallows `EnterPlanMode`/`ExitPlanMode`. Plan/review
use Read naturally to gather context; build runs in a loop where Claude edits
the working tree and the pipeline derives the canonical diff via `git diff`.

### Adjacent issues from the same run

1. Inter-stage data (plan.json → build prompt; plan.json + diff.patch → review
   prompt) is inlined as compact JSON run-on text — hard to read in banners and
   likely worse for LLM comprehension than markdown.
2. Stage-io banner shows the same compact JSON in `── input ──` sections.

## Decision

Define **two reusable invocation patterns** that any current or future pipeline
stage selects from. Pattern selection is a **plugin internal**: `template.yaml`
continues to list stages with `id`, `gate`, `roles`, and `io` config only. It
does NOT declare Pattern 1 vs Pattern 2 — that is baked into `plugin.sh`.

---

### Pattern 1 — "One-Shot with Tools" (`route_to_model`)

Single `claude --print` invocation. Tools (Read/Edit/Write/Bash) are available;
only `EnterPlanMode`/`ExitPlanMode` are disallowed. `--max-turns 25`,
`--dangerously-skip-permissions`.

The stage emits a final structured artifact (JSON or markdown) as its terminal
response. The pipeline captures stdout exactly as today — `claude --print` still
returns a single final response even when it used tools internally.

Scope declaration: the prompt states which paths the stage may read (scope-manifest
by default for read-only analyzers). Pipeline post-validates tool-use log if
available in `--output-format json` responses.

**Current users:** plan, review, security-lens.
**Future users:** design, compound_quality, TDD-spec, and any stage that produces
a structured artifact from analysis.

---

### Pattern 2 — "Agent-Loop with Derived Diff" (`route_to_model_loop`)

Multi-turn bash loop. Each iteration: invoke `claude` in `cwd`, capture `git diff`
between turns, append to next prompt. Terminates on `DONE` sentinel from the LLM
or a `max-iterations` cap. The pipeline derives the canonical artifact (e.g.
`diff.patch`) via `git diff` after the loop terminates — the LLM never emits a
diff string.

The loop itself is deterministic bash; the LLM is a subprocess called inside it.
Loop control logic (iteration count, termination condition, diff capture) is pure
bash.

Scope declaration: the prompt states which files the stage may touch (e.g.
`plan.files[]` for build). Pipeline post-validates the resulting diff:
- Parse all `diff --git a/<path>` entries.
- Assert each path is in the declared scope.
- If any path is out of scope: emit `*.scope.violation` event, write empty artifact,
  set `scope_violation=true` in the stage summary. The stage continues to the next
  pipeline step (review verdicts on the violation rather than the pipeline aborting).

**Current users:** build.
**Future users:** test-fix loops, deploy-validate retry loops, any stage where
iterative working-tree editing is required.

---

### Deterministic operations stay bash

Any operation with a single correct answer (does this diff apply cleanly? did
tests pass? does this path match the allowlist?) stays pure bash. The LLM is
invoked only when judgment or generation is required.

Concrete examples of operations that must NOT be delegated to the LLM:
- `git diff` to produce the canonical diff after a build loop.
- `git apply --check` to validate a diff.
- Test execution (`npm test`, etc.).
- Lint / coverage gate checks.
- Schema validation of plan.json / review.json.
- Scope post-validation (path membership check against an allowlist).

This is not a restriction on what the LLM *can* do inside a stage (it may run
`npm test` via the Bash tool as part of a build loop). It is a restriction on what
the **pipeline orchestrator** delegates: the orchestrator always re-runs the
deterministic operation itself to derive the canonical result.

---

### Artifact renderer registry

A new shared helper (`scripts/lib/artifact-render.sh`) provides a registry
pattern:

```bash
register_artifact_renderer <artifact-id> <render-fn>
render_artifact <artifact-id> <json-or-text-input>   # dispatches to registered fn
```

Built-in renderers: `render_plan_md`, `render_diff_md`, `render_review_md`.

Plugins register their own renderer via `register_artifact_renderer` in their
bootstrap — no edits to `artifact-render.sh` required.

The stage-io banner (`core/output/stage-io.sh`) recognises known artifact
filenames and passes them through `render_artifact` before display. Markdown
becomes the wire format between stages; JSON/patch files on disk remain the
source of truth.

---

### Extensibility contract

Adding a new stage is a plugin fill-in, not a template or router change:

| If the new stage… | Use pattern | Checklist |
|---|---|---|
| Produces a structured artifact from analysis | **Pattern 1** | (1) heredoc prompt; (2) declare scope source; (3) optionally register renderer |
| Iteratively modifies the working tree until a condition is met | **Pattern 2** | (1) heredoc prompt with DONE sentinel rule; (2) declare scope source; (3) define loop termination condition; (4) post-validate derived artifact |
| Deterministic only (tests, lint, diff apply, intake's `gh issue view`) | **No LLM** | Pure bash + emit events |

Once Issues A + B ship, adding any new stage requires zero changes to
`core/router/route.sh` or `template.yaml`.

## Decision points

1. `route_to_model` (`core/router/route.sh`) adopts shipwright's flag set —
   `--max-turns 25`, `--disallowed-tools "EnterPlanMode,ExitPlanMode"`,
   `--dangerously-skip-permissions` — enabling Pattern 1. *(Issue A)*
2. New `route_to_model_loop` function enables Pattern 2. *(Issue B)*
3. Plan and review prompts stop forbidding tool calls; invite Read for
   context-gathering. *(Issues C, D)*
4. Build no longer parses a diff out of LLM response text; uses
   `route_to_model_loop` + `git diff`. *(Issue B)*
5. Scope enforcement: prompt declares allowed paths; pipeline post-validates.
   Out-of-scope → `*.scope.violation` event, fail-closed. *(Issues B, C)*
6. Inter-stage data and banner rendered as markdown via the renderer registry.
   *(Issue E)*
7. Extensibility contract: Pattern 1 and Pattern 2 are the standing templates;
   new stages reference this ADR, not a new one.

## Amendment to ADR-004

ADR-004 established `apply_scope_redaction` as the single chokepoint through
which all LLM-bound text passes. That function is unchanged.

This ADR extends its interpretation: scope enforcement now operates at **two
layers**:
1. **Prompt layer** (ADR-004): the prompt text is redacted and declares the
   allowed scope.
2. **Post-validation layer** (ADR-018): after the LLM call, the pipeline
   validates the produced artifact (diff paths, plan file paths) against the
   declared scope. Violations are emitted as events, not silently dropped.

A plugin that invokes a model without passing through `route_to_model` or
`route_to_model_loop` is still a bug (per ADR-004). The second layer adds
defense-in-depth; it does not replace the first.

## Consequences

- **Build** becomes slower (agent loop = multiple turns) but correct (no
  fabrication; LLM edits real files).
- **Plan and review** become stronger (can read real files before producing
  outputs).
- **New stages** are cheap to add: pick pattern, write prompt, declare scope,
  optionally register renderer.
- **Banner** gains human-readable display for all known artifact types.
- **Backwards compatibility**: plan.json / diff.patch / review.json on disk are
  unchanged — only the prompt-and-banner rendering layer changes.

## Alternatives considered

### Sandbox-copy approach

Copy the working tree to a tmp directory, let Claude edit the copy, diff the copy
against the original. Rejected: the LLM must edit the *real* working tree so that
`git diff` against HEAD captures only changes relative to the committed baseline.
A copy-based approach would require reconstructing `HEAD` state inside the copy
and would break `git apply --check` validation. User explicitly rejected this
approach.

### Per-tool-call runtime hook

Intercept each tool call through a gate function before execution, check path
against allowlist, abort if out of scope. Rejected: introduces a new gating layer
with multiple decision points; harder to make fail-closed than post-validation; no
equivalent in shipwright's proven pattern.

### Continue with hardened headless-completion prompts

The #461/#462 prompts tell Claude "no tool calls, emit a diff." The dogfood run
`20260529164733-70084` shows that even well-crafted prompts cannot overcome the
fundamental pathology of asking an LLM to fabricate code it has never read.
Rejected.

## Implementation issues

| Issue | Title | Depends on |
|---|---|---|
| A | `router: adopt shipwright's claude flag set (ADR-018)` | ADR-018 merged |
| B | `build: agent-loop + git diff (ADR-018)` | Issue A |
| C | `plan: invite Read; post-validate step.files[] (ADR-018)` | Issue A |
| D | `review: invite Read for diff verification (ADR-018)` | Issue A |
| E | `core: artifact renderer registry + banner markdown (ADR-018)` | ADR-018; parallel to A/B/C/D |

## Implementation Notes (In Flight — 2026-05-29)

Issue A (`#466 — router adopts shipwright's claude flag set`) in flight on
branch `feat/466-router-flags`:

- `_route_call_claude` in `core/router/route.sh` now appends three flags
  before the JSON-mode toggle: `--max-turns <N>`,
  `--disallowed-tools "EnterPlanMode,ExitPlanMode"`,
  `--dangerously-skip-permissions`.
- New helper `_route_resolve_max_turns` mirrors ADR-017's
  `_route_resolve_timeout` and reuses `_route_resolve_knob` (extended with
  an optional 4th event-name argument so the override-ignored event type
  can vary per knob). Precedence: per-stage `router.max_turns` > env
  `ZBUILD_ROUTER_MAX_TURNS` > compile-time default `25`. Invalid values
  (non-integer, `<1`, `>200`) return rc=2 with `router.error
  reason=invalid_max_turns`.
- Template parser (`core/pipeline/template.sh::_tpl_parse_stage_data`)
  recognises `router.max_turns:` as a sibling of `timeout_s`; pipe-
  delimited emit grows from 7 to 8 fields. Validator
  `_tpl_validate_io_knobs` extended with a 5th nameref arg and rejects
  values outside `1..200` with the actionable error
  `template: router.max_turns for stage '<id>' must be integer in 1..200,
  got: <val>`.
- Name-mangled env var `_TPL_STAGE_ROUTER_MAX_TURNS_${safe_id}` is appended
  to the `export` statement (#448 lesson — plugin subshells must inherit
  the per-stage knob).
- Accessor `template_stage_router_max_turns` added.
- `router.max_turns.override_ignored` added to
  `config/event-schema.json::known_types`.
- `config/templates/standard.yaml` ships `max_turns: 25` defaults on plan
  and review; build deliberately omits the knob (Issue B will set the
  agent-loop value).
- Test coverage: `tests/unit/router-claude-flags-test.sh` (28 assertions),
  `tests/integration/router-claude-flags-test.sh` (7 assertions across
  the subprocess boundary, locks the export + comma-preservation
  contract).

Issue C (`#468 — plan: invite Read; post-validate step.files[]`) in flight on
branch `feat/468-plan-invites-read`:

- `_plan_instructions` heredoc in `plugins/agent/plan/plugin.sh` rewritten:
  the "no tool calls" prohibition is gone; the prompt now splits into a
  "Tool use" clause that invites the Read tool and forbids Edit/Write/Bash,
  and an "Output contract" clause that demands a single JSON object with no
  markdown code fences.
- The scope-manifest is inlined verbatim into the prompt body after the
  goal, prefixed with "Scope manifest (allowed path prefixes):". This is
  ground truth — avoids round-trip on `apply_scope_redaction` markers and
  removes a hallucination axis.
- New helper `_plan_validate_scope` walks `plan.steps[].files[]` via
  `jq -r '@tsv'`, normalizes each path (strips leading `./`), rejects
  absolute (`^/`) and `..`-traversal segments, and prefix-matches the
  remainder against the manifest allowlist parsed with the same awk shape
  used by `core/redaction/scope-redaction.sh:75`. One
  `plan.scope.violation` event is emitted per offender with flat k=v
  payload (`plugin`, `stage`, `step_id`, `path`, `reason`, `scope_hash`,
  `manifest_path`). `reason` is one of `out_of_scope`, `absolute_path`,
  `out_of_repo`.
- Fail-soft: `plan.json` is written regardless of violations; the
  count is added to the existing `plugin.run.complete` payload as
  `scope_violations=<N>`; `rc=0` on violations.
- Schema validator tightened: the `jq -e` predicate now asserts
  `(.steps | all((.files | type=="array") and (.files | all(type=="string"))))`.
  Malformed plans still rc=1 with `plugin.run.error reason=invalid_plan_response`.
- `plan.scope.violation` added to `config/event-schema.json::known_types`.
- Test coverage: `plugins/agent/plan/tests/plan-test.sh` extended (42
  assertions including new Test 3c prompt assertions and Tests 6–13 for
  scope post-validation); new
  `plugins/agent/plan/tests/plan-integration-test.sh` (7 assertions, stubs
  a real `claude` binary on PATH to cross the subprocess boundary). New
  goldens under `tests/golden/`: `plan-in-scope.golden`,
  `plan-out-of-scope.golden`, `plan-scope-violation-event.golden`.

Issues B, D, E remain pending; this section will be updated to `Accepted`
and this paragraph rewritten with PR links as each merges.

Dogfood run `20260529164733-70084` is the triggering evidence on record.
