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
response.

**JSON envelope is mandatory when tools are available.** `claude --print` *without*
`--output-format json` streams every turn — reasoning, tool calls, and final
answer — as concatenated text. Only `.result` from the JSON envelope is the
final assistant message; reasoning lives in separate fields. Plugins MUST set
`ZBUILD_ROUTER_JSON_OUTPUT=1` around their `route_to_model` call and consume
only `.result`. The router enforces `--output-format json` at the boundary
and auto-extracts `.result`
(`core/router/route.sh:315, 350-352`); plugins enforce the contract at the call
site. Without this, reasoning preambles leak into the response and break strict
JSON parsers downstream (#476).

The envelope separates reasoning *turns* from the final turn, but the model can
still emit prose **inside** the final turn before/after the JSON object.
Pattern 1 plugins MUST run `.result` through `extract_first_json_object`
(`scripts/lib/helpers.sh`) before `jq` validation. This is a durable safety
net; prompt instructions alone are best-effort (#478).

Two defenses now cover envelope-mode in-turn prose (#510):
1. **Parser side** — `extract_first_json_object` (existing, #478) slices the
   LAST balanced top-level object so plugins persist a clean artifact to disk.
2. **Banner side** — `extract_json_and_surrounding_prose` (new, #510) returns
   both the JSON slice AND the surrounding prose so `render_plan_md` /
   `render_review_md` can split the OUTPUT banner into the rendered artifact
   FIRST followed by a `── llm comment ──` block. The on-disk capture record
   stays raw — see ADR-015 §v5 Implementation Note.

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

#### Implementation Notes — corrupt-diff gate (issue #509)

The post-loop diff captured via `git diff HEAD` (with the `git add -N`
pre-pass that surfaces untracked files) can be syntactically corrupt without
the loop or scope-validation noticing: zero-line stat entries for empty
files, binary-file stubs missing a full index line, and stale `@@` line
numbers after cumulative multi-iter edits all produce diffs that
`git apply --check` rejects. Before #509 these patches were written to
`diff.patch` silently and only surfaced when the downstream test stage
tried to apply them.

The gate lives in `plugins/agent/build/plugin.sh::_build_apply_check`,
NOT the router — router stays diff-format-agnostic per Pattern 2. The
helper runs `git apply --check -R` (reverse, because the working tree
already holds the changes the diff describes) before the single
`atomic_write` of `build-summary.json`, and folds its outcome into a new
top-level `.apply_check` object on the summary. Fail-CLOSED: a corrupt
patch sets `verdict=corrupt_diff` AND makes the plugin return rc=1, so
`core/pipeline/runner.sh:672-686` halts the pipeline via the rc-wins
path. The diff is still written (for triage), but the test stage never
runs.

Precondition mitigations mirror `_build_emit_changed_files_summary`:
detached/unborn/rebase/merge/bisect state short-circuits to
`reason=precondition_failed` fail-CLOSED rather than running the check on
an unstable tree. Missing git binary → `reason=tool_unavailable`,
catastrophic `git apply` rc>1 → same. Empty diff is skipped (the existing
`build.empty_diff` event still fires upstream).

**Amendment (#529)** — The `rc>1 → tool_unavailable` collapse in
`_build_apply_check` conflated two distinct semantic classes. As of #529 the
gate stderr-classifies before rc-bucketing: rc=128 with `^error: corrupt patch`
resolves to `reason=corrupt_format` (fail-CLOSED, parser rejected payload);
rc=128 with `^fatal:` resolves to `reason=tool_state` (fail-CLOSED, git
environment defect — typically broken-index or unreachable HEAD discovered
mid-apply). Only `rc=127` and "binary missing" map to `tool_unavailable`.
Any other unexpected rc surfaces as `reason=other` with `git_apply_rc`
captured verbatim. Every failure event carries
`apply_check.classifier_branch=<tag>` for triage (tags: `corrupt_format`,
`tool_state`, `tool_unavailable_127`, `git_missing`, `binary`,
`missing_target`, `context`, `ws_warn`, `precondition`, `stub_guard`,
`other`). Router-side `_route_loop_capture_diff` (`core/router/route.sh:838`)
retains coarser single-bucket behavior because the authoritative gate
downstream re-classifies — tracked as a follow-up rather than expanded scope
here.

**Amendment (#530) — Diff capture trailing-newline contract.** The
`route_to_model_loop` + build plugin diff capture path round-tripped
`git diff HEAD` through bash command substitution (`$()`), which strips
trailing newlines. Combined with `printf '%s'` (no `\n`), this produced
patches missing their terminal newline — apply-check forward fails ("corrupt
patch at line N"), reverse passes (the #519 mask). The fix: write `git diff
HEAD` directly to the artifact file via `git diff HEAD > diff.patch`,
bypassing bash variables. Downstream consumers (stats parsers, scope check)
read the file back with the lossless `cat file; printf x` trick so the
trailing newline survives a round-trip through bash. The
`_route_loop_capture_diff` helper uses the same disk-tempfile-readback
pattern for the prev_diff prompt-feedback variable.

The `_build_apply_check` gate is extended to run BOTH forward and reverse
checks: forward via `git reset` (drop `-N` index entries) → `git stash
push -u` → `git apply --check <patch>` → `git stash pop` → restore index,
plus the existing reverse check. Both must pass for `ok:true`. New summary
fields: `apply_check.forward_ok`, `apply_check.reverse_ok`. The reverse-
only check from #509 was structurally blind to forward-only corruption
(same parser, same byte stream).

Hunk-count structural validation runs an awk pass on the patch text and
parses each `@@ -a,b +c,d @@` header. The following `-`/` `/`+` line
counts must agree with `b`/`d` for every hunk; the LAST hunk's mismatch
is the canonical truncation signature. Hits emit
`build.invariant.hunk_count_mismatch` and set `truncation_observed=true`
in `apply_check`.

Additional defense-in-depth: after writing `diff.patch`, the plugin
verifies the last byte is `\n` and appends one if not, emitting
`build.diff.trailing_newline_restored` if the canary fires (should not
post-fix). NUL-byte scan flags `build.diff.binary_truncation_observed`
when binary diffs would otherwise truncate silently through bash
variables. After the diff is written and scope-validated, the `git add
-N` intent-to-add index entries are cleared via `git reset` so the
downstream test stage's rsync sees a clean index.

**Amendment (#602) — Strip the stash dance; LLM edits ARE the diff.** The
`_build_apply_check` gate from #509/#530 ran `git stash push -u` →
`git apply --check` → `git stash pop` to validate the captured patch
against a clean tree. `git stash pop` is documented as best-effort; in
practice it silently failed on any conflict between the stashed working
tree and the patch-touched files, leaving the LLM's edits hidden in the
stash. Dogfood `20260601074651-63429` cycled to exhaustion with
`numstat=0/0/0` every iter because every build run quietly stashed its
own work. Legacy shipwright (`legacy/scripts/lib/pipeline-stages-build.sh`)
never did this dance — its `sw loop` runs in-place and the next iter's
`git diff` reads the working tree directly.

Post-#602 contract for Pattern 2:

> The LLM edits the working tree directly via Edit/Write tools. The
> pipeline captures `git diff HEAD` after the loop terminates; no
> intermediate stash or apply-check dance. The captured diff IS the
> canonical `diff.patch` artifact for downstream stages. Diff
> applicability is validated by the LLM's actions, not by post-hoc
> machinery. The downstream test stage rsyncs the working tree
> (incl. the LLM's edits) into a temp dir and runs tests directly —
> no `git apply` step.

Removed in #602: `_build_apply_check` (~324 LOC), the bidirectional
forward+reverse machinery, the `apply_check` field on `build-summary.json`
(schema_version 3 → 4), the test plugin's `git checkout HEAD -- .` /
`git clean -fd` reset, the test plugin's `git apply --check` / `git apply`
steps, and four event names (`build.apply_check.{failed,skipped,unavailable,
precondition_failed}`). Kept: scope-violation detection,
`build.diff.empty_after_done_sentinel` discrepancy event, and the
`git diff HEAD` capture itself (the canonical diff artifact).

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
8. **Pattern 1 stages that invite tool use MUST opt into JSON envelope mode.**
   Plugins export `ZBUILD_ROUTER_JSON_OUTPUT=1` around the `route_to_model`
   call and consume only `.result`. Text-streaming mode (the default for
   `claude --print` without `--output-format json`) leaks reasoning turns as a
   prose preamble that breaks strict-JSON parsers (#476).

   ```bash
   # Save/restore template for Pattern 1 plugins:
   local _prev_json_env="${ZBUILD_ROUTER_JSON_OUTPUT-__UNSET__}"
   local _prev_artifact_env="${ZBUILD_ROUTER_ARTIFACT_ID-__UNSET__}"
   export ZBUILD_ROUTER_JSON_OUTPUT=1
   export ZBUILD_ROUTER_ARTIFACT_ID="<plugin-id>"
   # call route_to_model here
   if [[ "$_prev_json_env" == "__UNSET__" ]]; then
       unset ZBUILD_ROUTER_JSON_OUTPUT
   else
       export ZBUILD_ROUTER_JSON_OUTPUT="$_prev_json_env"
   fi
   if [[ "$_prev_artifact_env" == "__UNSET__" ]]; then
       unset ZBUILD_ROUTER_ARTIFACT_ID
   else
       export ZBUILD_ROUTER_ARTIFACT_ID="$_prev_artifact_env"
   fi
   ```

   This idiom is verified across all 3 Pattern 1 plugins (plan/review/security-lens).
   Codifying it prevents future regressions.

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

Issue C (`#468 — plan: invite Read; post-validate step.files[]`) merged on
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

Issue D (`#469 — review invites Read for diff verification`) merged on
branch `feat/469-review-invites-read`:

- `_review_instructions` heredoc in `plugins/agent/review/plugin.sh`
  rewritten as three distinct clauses (final-output contract, tool-use
  invitation, scope-redaction reminder). The literal phrase "no tool
  calls" from #462 is removed; Read is explicitly invited for diff
  verification; Edit/Write/Bash remain forbidden in the prompt text;
  `<out-of-scope-context>` markers are called out so the model does
  not attempt to Read redacted paths.
- Opt-in audit gated by `ZBUILD_REVIEW_AUDIT_TOOL_USE=1`. When enabled,
  the plugin exports `ZBUILD_ROUTER_JSON_OUTPUT=1` to switch the router
  into JSON envelope mode and `ZBUILD_ROUTER_TOOL_USES_FILE=<path>` to
  request that `_route_call_claude` write the captured `tool_uses[]`
  array to a side-channel file (route_to_model is called via `$()`
  which would otherwise discard the in-subshell `_ROUTE_TOOL_USES_JSON`
  state). After the call the plugin parses the file and, for each Read
  whose `input.file_path` is not covered by the scope-manifest
  allowlist, emits `review.scope.violation` with `path=<offender>` and
  `scope_hash=<sha256>`. Warn-only — the verdict is NOT coerced; this
  is defense-in-depth per the ADR-004 amendment above.
- When `ZBUILD_REVIEW_AUDIT_TOOL_USE` is unset (default), the plugin's
  behavior is identical to pre-#469: bare-text JSON parse path, no
  envelope unwrap, no audit events.
- `review.scope.violation` added to
  `config/event-schema.json::known_types`.
- Test coverage extended in
  `plugins/agent/review/tests/review-test.sh`:
  - Test 8 inverts the #462 "no tool calls" assertion to a NEGATIVE
    check and adds positives for Read invitation, Edit/Write/Bash
    prohibition, `<out-of-scope-context>` awareness.
  - Tests 9–10: prompt declares scope-bounded reads; happy-path
    verdict round-trip regression.
  - Tests 11 / 11b: audit-on emits violations for out-of-scope Read,
    no false-positive for in-scope path; audit-off emits no events.
  - Test 12: subprocess-boundary contract — a real mock `claude`
    binary on PATH emits the JSON envelope; the router unwraps it,
    writes `tool_uses[]` to the side-channel, the plugin parses the
    side-channel back and emits the violation event.

Issue B (`#467 — build: agent-loop + git diff (ADR-018 Pattern 2)`) in
flight on branch `feat/467-build-agent-loop`:

- New `route_to_model_loop` in `core/router/route.sh` implements Pattern 2.
  Signature `<tier> <prompt_file> <cwd> <max_iterations> [--max-turns-per-call N]
  [--done-sentinel TOKEN] [--inter-turn-hook FN] [--model ID]
  [--scope-allowlist CSV]`. Each iteration fuses a static prompt with
  `git diff HEAD` from the prior turn, redacts via `apply_scope_redaction`
  (per-iteration C6), invokes claude with `--output-format json`,
  extracts `.result`, and grep-anchors `^[[:space:]]*LOOP_COMPLETE[[:space:]]*$`.
  Sets globals `_ROUTE_LOOP_ITERATIONS`, `_ROUTE_LOOP_TERMINATED_REASON`,
  `_ROUTE_LOOP_INPUT_TOKENS`, `_ROUTE_LOOP_OUTPUT_TOKENS`. Returns 0
  (DONE), 1 (max-iter), 2 (fatal). 3 consecutive timeouts → fatal.
  `git diff HEAD` failure → fatal + `loop.git_diff_failed`. SIGINT/SIGTERM
  trap kills the child and emits `loop.terminated.signal`. Diff cap
  default 20000 chars (`ZBUILD_LOOP_DIFF_CAP_CHARS`); overflow falls back
  to `git diff --stat` + warn event.
- `core/pipeline/template.sh` gains `router.max_iterations` knob (1..50)
  mirroring `max_turns` from #466. Default 10 via env
  `ZBUILD_ROUTER_MAX_ITERATIONS` or compile-time fallback. Pipe-delimited
  emit grows 8 → 9 fields. Accessor `template_stage_router_max_iterations`.
- `plugins/agent/build/plugin.sh` rewritten: build prompt now invites
  Read/Edit/Write/Bash tools, declares scope from `plan.files[]`, and
  requests `LOOP_COMPLETE` as the terminal sentinel. Replaced
  `route_to_model` + awk diff extractor with `route_to_model_loop` +
  `git -C "$repo_root" diff HEAD` after the loop. `git add -N .` runs
  pre-diff so untracked files appear in the canonical artifact.
- Scope post-validation walks `git diff --name-status -z HEAD` (NUL-safe
  via tempfile read — bash command substitution strips NULs). Renames
  (`R*`) check both old and new path; deletions (`D`) check the deleted
  path. Prefix match: a plan path covers descendants. Violations are
  fail-soft: empty `diff.patch`, `build.scope.violation` event per
  offender, `scope_violation=true` in summary, rc=0.
- `build-summary.json` bumped to `schema_version=2`; new fields
  `iterations`, `terminated_reason` (one of `done_sentinel | max_iterations
  | signal | hook_failed | error`), `scope_violation`, `scope_violations`,
  `loop_input_tokens`, `loop_output_tokens`.
- New event types added to `config/event-schema.json`: `loop.iteration`,
  `loop.iteration.error`, `loop.complete`, `loop.max_iterations`,
  `loop.git_diff_failed`, `loop.terminated.signal`,
  `loop.diff_capture_warning`, `build.scope.violation`, `build.empty_diff`,
  `router.max_iterations.override_ignored`.
- Test coverage: `core/router/tests/route-loop-unit-test.sh` (31
  assertions — single-iter DONE, multi-iter DONE, max-iter cap, rc!=0
  recovery, sentinel parsing variants including whitespace/lowercase
  rejection, diff-cap fallback, argument validation).
  `plugins/agent/build/tests/build-test.sh` updated to 40 assertions —
  drops obsolete diff-format prompt checks, exercises real temp git
  repos, validates the new schema_version=2 fields, and adds T6 for the
  scope-violation path.
- ADR-004 amendment honored: per-iteration redaction event is emitted
  immediately before each claude call inside the loop, satisfying the C6
  precondition for every turn.

Issue E remains pending; this section will be updated to `Accepted` and
this paragraph rewritten with PR links as it merges.

Decision point #8 — JSON envelope mandatory for Pattern 1 with tools
(`#476`, follow-up to the wave above):

- Triggering dogfood run on `7b20640` against `--issue 294`: plan stage
  failed with `invalid_plan_response` because `claude --print` streamed a
  reasoning turn ("Now I have a full picture…") as a prose preamble
  before the final JSON. The `jq -e` validator rejected the run-on
  string.
- Root cause: the router has supported `--output-format json` + `.result`
  extraction since the Pattern 2 work (`core/router/route.sh:315, 350-352`),
  but Pattern 1 plugins (plan, security-lens, and review's default path)
  never opted in. Only `route_to_model_loop` (#467) and review's audit
  branch (#469) used the envelope.
- Fix (in flight on `fix/476-pattern1-json-envelope`):
  - `plugins/agent/plan/plugin.sh`, `plugins/agent/security-lens/plugin.sh`,
    `plugins/agent/review/plugin.sh` each wrap their `route_to_model`
    call with `export ZBUILD_ROUTER_JSON_OUTPUT=1` / `unset` (mirror
    review's existing pattern from #469).
  - Review's restructure: envelope-mode export is now unconditional; the
    `ZBUILD_REVIEW_AUDIT_TOOL_USE` gate only controls the tool-uses
    side-channel.
  - Decision point #8 codifies the rule in §"Pattern 1" so future stages
    (design, compound_quality, etc.) inherit it.
- Tests extended:
  - Unit shadows of `route_to_model` capture `ZBUILD_ROUTER_JSON_OUTPUT`
    at call time and assert it equals `1`.
  - Integration `claude` stubs on PATH branch on `--output-format json`
    argv: emit an envelope `{"type":"result","subtype":"success","result":"..."}`
    when present, raw text otherwise. Locks the subprocess-boundary
    contract for plan, review, and security-lens.

Dogfood run `20260529164733-70084` is the triggering evidence on record.

Decision point #8 reinforcement — parser-side JSON extraction (`#478`,
follow-up to `#476`):

- Triggering evidence: even with envelope mode on, dogfood runs continued to
  fail because the model emitted prose INSIDE its final assistant message
  (e.g. "Now I have a complete picture.\n\n{...}"). The envelope separates
  reasoning *turns* from the final turn; it does not separate prose from JSON
  within the final turn.
- Fix: new helper `extract_first_json_object` in `scripts/lib/helpers.sh`. Pure
  awk state machine, string-aware brace scan, top-level-only (object-only
  contract — top-level arrays pass through), folds in markdown ```json fence
  stripping as a pre-pass. The algorithm returns the **LAST** top-level
  balanced object (models tend to emit examples first, real answers last); the
  function name is kept from the issue title for thread continuity. On
  no-match the input passes through verbatim so #476 reason= diagnostics
  (`schema_violation` vs `empty_result_envelope`) still classify correctly.
- Wired into `plugins/agent/plan/plugin.sh`,
  `plugins/agent/review/plugin.sh`, `plugins/agent/security-lens/plugin.sh`
  in place of the per-plugin 3-line sed fence-strip pipeline. Downstream
  `jq -e` validation unchanged.
- Prompt hardening: every Pattern 1 instruction heredoc now appends "Your
  response MUST begin with `{` and contain nothing other than the JSON object
  — no leading prose, no trailing prose, no markdown fences." after its
  existing "no commentary before or after" clause. Helper is the durable
  safety net; the prompt rule is best-effort.
- Test coverage: `tests/unit/extract-first-json-object-test.sh` locks E1–E18
  (regression locks on LAST-wins, string-aware scan, passthrough on no-match,
  array passthrough, UTF-8 BOM, perf budget). Plan, review, and security-lens
  test suites gain a "#478 prose-prefix" regression case plus prompt
  assertions for the new sentence. `plan-integration-test.sh` adds variant 3
  to lock the parser-side extraction across the subprocess boundary.

Producer-side banner rendering parity (`#483`, follow-up to `#470`/`#476`):
the renderer registry dispatch at `core/output/stage-io.sh` was input-side
only — the consumer's input banner rendered through `render_artifact`, but
the producer's own output banner fell through to the pretty-print path and
showed raw JSON. `#483` closes the asymmetry with a new env-var
`ZBUILD_ROUTER_ARTIFACT_ID` (symmetric to `#476`'s
`ZBUILD_ROUTER_JSON_OUTPUT`). When set, `route_to_model` appends
`--metadata artifact=<id>` to the `capture_stage_io` call, and
`_stage_io_to_stdout`'s `llm` branch now dispatches `render_artifact "$id"
"$output"` BEFORE the pretty-print fallback (mirror of the existing input
branch from `#470`). Plan exports `=plan`, review `=review`, security-lens
`=security-lens`; each wraps with the same `_prev_artifact_env="${VAR-__UNSET__}"`
save/restore pattern as `#476`. The `security-lens` renderer is not yet
registered — `render_artifact` passthrough + `stage.io.render.fallback`
event are intentional until a follow-up adds `render_security_lens_md`.
Coverage: `tests/unit/core-output-stage-io-render-test.sh` adds B5–B7 for
the output dispatch; `tests/unit/agent-stages-artifact-metadata-symmetry-test.sh`
(NEW) is the cross-plugin parity lock; `tests/integration/agent-stage-banner-rendered-markdown-test.sh`
(NEW) crosses the subprocess boundary with the real envelope-mock claude on
PATH and captures fd 3 to assert markdown headings in the OUTPUT banner.

### Pattern 2.5 — banner-vs-payload divergence in loops (issue #505)

Pattern 2's per-iteration `stage_io_begin/end` pair (`#482`) initially emitted the same string to BOTH the operator scrollback banner AND the artifact `.input` field. In long loops this produced redundant noise: iter 2+ repeated the full static prompt verbatim AND the cumulative `git diff HEAD` block, which is also rendered immediately afterward by build's `── changed-files ──` summary banner (`#498`). Operators reading the scroll had no fast way to confirm "same prompt as iter 1, just see the diff below".

**Decision (#505):** for `route_to_model_loop` only, the per-iteration banner DEDUPES the static prompt and REPLACES the cumulative diff section with a pointer once `iter ≥ 2`. The LLM payload is unchanged — `claude -p` always receives the full prompt. Artifact `.input` is unchanged — the new `stage_io_begin --persist-input <path>` flag writes the full prompt into the file record, preserving postmortem fidelity. Only the scrollback banner CONTENT diverges.

Banner shape on iter ≥ 2:

```
[static prompt: same as iter 1, <N> lines, sha=<short8>]

## Iteration ${iter}/${max_iterations}

[diff: see ── changed-files ── summary below (<N> lines, <chars>c)]
```

`sha` is the first 8 hex chars of `sha256(static_prompt)`, so mid-loop static-prompt mutation surfaces immediately (the pointer's sha changes between iterations). Three variants of the diff pointer are emitted:

- `[diff: see ── changed-files ── summary below (<N> lines, <chars>c)]` — normal case.
- `[diff: stat-only, see ── changed-files ──]` — when `_route_loop_capture_diff` returned the cap-exceeded `git diff --stat` payload (`route.sh` ~line 792).
- `[diff: unchanged from iter N-1]` — when the prev-iter diff snapshot is byte-identical (signals the loop has stalled on a no-op turn).

**Edge cases / opt-out:**

- iter 1 is always full (no prior context to dedupe against).
- iter 1 with empty `prev_diff` (route.sh:587–591) is the pre-existing special-case path; dedupe machinery is skipped (the iter-1 banner is the full prompt anyway).
- Dedupe is skipped entirely when `len(static_prompt) < ${ZBUILD_LOOP_BANNER_DEDUPE_MIN_CHARS:-500}` — below that threshold the operator gains nothing from a pointer.

**Tests:**

- `tests/unit/core-router-loop-banner-test.sh` (NEW) is the contract lock. Drives a 3-iter happy-path loop with a rotating mock claude that records argv + `-p` prompt per call; asserts (a) the full static-body sentinel appears in EVERY `claude -p` call; (b) iter ≥ 2 banner contains the `[static prompt: same as iter 1` and `[diff: ` pointers; (c) iter ≥ 2 banner does NOT contain the full static body; (d) `state/artifacts/stage-io/build-*.json` `.input` contains the full static body for ALL three iters (persist-input fidelity).
- `tests/integration/build-loop-banner-test.sh` gains a regression guard at iter 2/3 that asserts `.input` carries the full prompt sentinel even when banner is deduped. Pre-existing ordering + count assertions are unchanged.
- `tests/integration/stage-io-ordering-invariant-test.sh` (#491 keystone) remains content-agnostic and continues to pass — the begin-before-LLM, end-after-LLM ordering is unchanged.

**Compatibility:** `--persist-input` is a NEW optional flag on `stage_io_begin`. Callers that do not pass it (`route_to_model`, plan/review/security-lens via `capture_stage_io`) are byte-identical to v5 — divergence is opt-in, loop-caller-only.

## Amendment — Inner loop (Pattern 2) vs outer cycles (issue #512, ADR-021)

ADR-021 introduces an **outer cycle** that iterates a contiguous group of
canonical stages (e.g., `build → test`). Pattern 2 in this ADR
(`route_to_model_loop`) is the **inner loop** that iterates a single
stage's LLM calls. The two are orthogonal and compose:

| Layer | Concern | Termination | Owner |
|---|---|---|---|
| Outer cycle (ADR-021) | Multiple stages converging together | `until:` predicate on stage verdict, `max_iterations`, plateau, divergence | `cycle_orchestrator_run` |
| Inner loop (ADR-018 Pattern 2) | One LLM agent iterating its own edits | `LOOP_COMPLETE` sentinel, `max-iterations` cap, signal | `route_to_model_loop` |

Shared convergence vocabulary:
- Both emit `*.complete` events at terminal state.
- Both have a hardcoded ceiling (`_CYCLE_ABSOLUTE_MAX=10` outer; 50 inner).
- Both install INT/TERM traps but NEVER own EXIT (runner does).

When an outer cycle dispatches a build stage that internally uses Pattern 2,
the build plugin's inner loop runs to completion, returns rc + verdict, and
the outer cycle records that as iter N's outcome. The two layers do not
interfere with each other's state.

## Amendment — `test_assessment` as a Pattern 1 stage (issue #572, 2026-05-31)

ADR-022 introduces a new canonical stage, `test_assessment`, slotted between
`test` and `review`. It is a Pattern 1 stage by construction and joins the
existing Pattern 1 roster.

**Current users (amended #572):** plan, review, security-lens,
**test_assessment**. The `test_assessment` stage consumes `test-results.json`
(raw counts + producer verdict from the `test` tool stage) and interprets
test output into a structured verdict envelope. Like other Pattern 1
plugins, it MUST set `ZBUILD_ROUTER_JSON_OUTPUT=1` and
`ZBUILD_ROUTER_ARTIFACT_ID=test_assessment` around its `route_to_model`
call, route final output through `extract_first_json_object`, and register
a renderer `render_test_assessment_md` via `register_artifact_renderer`
(see §"Artifact renderer registry" above).

Decision points list grows by one:

9. `test_assessment` is a Pattern 1 stage by construction: deterministic
   test execution stays in the `test` tool plugin (per the "Deterministic
   operations stay bash" clause above); LLM interpretation of the test
   signal is a separate Pattern 1 stage feeding review (ADR-019 §7) and
   the `build_test_cycle`'s `until:` predicate (ADR-021 amendment for
   #572). See ADR-022 for the full Status / Context / Decision /
   Consequences record.

## Amendment — Loop-completion contract adds `COMMIT_SUMMARY` (issue #608, 2026-05-31)

The Pattern 2 loop-completion contract is extended: the LLM emits
`COMMIT_SUMMARY: <one-line>` immediately before the final `LOOP_COMPLETE`
sentinel. The pipeline parses this marker from the last iteration's
`.result` text (now exposed via `_ROUTE_LOOP_LAST_RESPONSE`) and uses it
as the message of the per-iteration commit it creates on the LLM's behalf
(see ADR-021 amendment for the cycle-level rationale).

The contract:

- LLM emits `COMMIT_SUMMARY: <msg>` on its own line before `LOOP_COMPLETE`
- Pipeline scans the last 50 lines of the final iteration response for
  the regex `^COMMIT_SUMMARY:[[:space:]]*(.+)$`; LAST match wins
- Message is trimmed and truncated to 72 chars (git short-message
  convention)
- Fallback: when the marker is absent, the pipeline uses `plan.title`
  from `plan.json`; when that is also empty, it synthesizes
  `zbuild: build iter <N>`
- The LLM does NOT run `git commit` — the pipeline owns commit semantics
  (this was always the contract; #608 makes the pipeline honor it)

Implementation: `plugins/agent/build/plugin.sh::_build_parse_commit_summary`
and `::_build_commit_iteration`. The instruction is rendered into every
build prompt's INSTRUCTIONS section via `_build_compose_instructions`.

## Amendment 1 (Wave 19-M, #762/#763) — `max_turns: 0` sentinel for unbounded turns

The original contract bounded `router.max_turns` to integer `1..200`. The build
stage's Pattern-2 inter-turn loop exhausts 25 turns on legitimate multi-file
refactors (#754 dogfood: hit cap at 10K output tokens, $1.21 cost), and the
underlying `claude` CLI treats an absent `--max-turns` flag as "no per-invocation
cap" (provider-side cap still applies).

Revised contract: `router.max_turns` accepts integer `0..200`.

- `0` is a sentinel meaning "omit `--max-turns` from claude argv". The flag is
  not passed; provider-default applies. Negatives and >200 remain
  `reason=invalid_max_turns`.
- Precedence unchanged: per-stage template > `$ZBUILD_ROUTER_MAX_TURNS` > 25.
  Env-var `ZBUILD_ROUTER_MAX_TURNS=0` is honored with identical semantics.
- Loop mode: the resolved sentinel applies to the per-call `--max-turns` flag.
  The loop's separate `max-iterations` cap (this ADR §"Pattern 2") is
  unaffected and retains its `1..50` validator. Explicit
  `--max-turns-per-call` overrides ALWAYS enforce `1..200` (sentinel rejected
  for per-call overrides per Copilot review #764).
- Telemetry: a new event `router.max_turns.flag_omitted` (payload: `resolved=0`,
  `source=template|env|default`) is emitted when the sentinel is the resolved
  value. The existing `router.max_turns.override_ignored` event keeps its
  prior semantics (per-stage vs env conflict only). Source classification is
  numeric (`-eq 0`) so values like `"00"` / `"000"` (accepted by the
  `^[0-9]+$` validator) classify correctly.
- Default for all LLM stages remains 25. `build` opts into the sentinel in
  `config/templates/standard.yaml`; other stages would need a separate ADR
  to adopt.

Rollback: revert the three validators (`core/router/route.sh` L355, L716;
`core/pipeline/template.sh` L953) to `-lt 1` and drop the conditional argv
hoist. Templates with `max_turns: 0` would fail validation post-rollback,
which is the desired loud failure mode.
