# ADR-004: Redaction Chokepoint

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy scope-redaction safety primitive is invoked from **9 distinct call sites** today (verified in KEEPERS §C corrections). Every site calls `_redact_paths_outside_scope` directly with inline allowlist and cycle parameters. No wrapper function exists.

This is the highest-leverage safety mechanism in the system: it prevents an LLM agent from being shown paths it shouldn't see (out-of-scope files, sibling repos, credentials elsewhere on disk). Today's pattern works but is fragile — a new prompt-emitting code path can be added without going through redaction, and nothing in CI catches it.

Examples of what could leak without redaction:
- A scope-violation in a `find_files` output containing absolute paths.
- An adversarial diff fed into a security-lens prompt that includes paths outside the design's scope manifest.
- A git diff emitted into a developer-simulation prompt where the diff straddled a scope boundary.

## Decision

zBuild has **one** function that emits LLM-bound text. All 9 (or however many in the future) prompt sites pass through it.

> **Superseded in part by [ADR-043](ADR-043-redaction-by-construction.md):** the redaction *call* is now owned by the router's model-call path (`route_to_model` / `route_to_model_loop`), not by each plugin. `apply_scope_redaction` remains the single chokepoint; ADR-043 only inverts *who invokes it* (router by construction, unless a plugin already redacted). The fail-closed contract below is unchanged.

### The chokepoint

```bash
core/redaction/apply_scope_redaction()
```

Signature (bash):
```bash
apply_scope_redaction <text_var> <scope_manifest_path> <allowlist_csv> <cycle_id>
```

Behavior:
1. **Refuse to emit** if `scope_manifest_path` is unset, empty, or unreadable. Emit synthetic blocking finding via event bus; return non-zero. (Fail-closed; absent evidence IS blocking evidence.)
2. Strip absolute and repo-relative paths outside the allowlist + scope-manifest entries.
3. Replace with `<out-of-scope-context>...</out-of-scope-context>` markers; preserve code-fence boundaries verbatim.
4. Emit `redaction.applied` event with `{prompt_size, redactions_count, scope_hash, cycle_id}`.
5. Idempotent — running twice produces identical output. Detected by a content hash on the wrapped output.

### Enforcement

- **Test:** `tests/unit/redaction-chokepoint-test.sh` greps the repo for `<claude\|<curl.*anthropic` invocations outside `core/redaction/` and `core/router/`; any match fails the test. (Per ADR-012, this lives in `tests/unit/` because it's a static repo scan, not an end-to-end integration.)
- **Code review:** PR checklist includes "Does this PR introduce a new LLM call?" → if yes, "Does it go through `core/redaction/apply_scope_redaction`?"
- **Manifest:** plugins MUST declare `requires.core: [redaction]`; the registry refuses to load a `kind: agent` plugin without it.
- **Redaction by construction (ADR-043):** every `model.route` event MUST be preceded by a `redaction.applied` event within the same `run_id` + `stage`. As of ADR-043 this is guaranteed *by construction*: `route_to_model` redacts the prompt itself unless a plugin already did (the former C6 "refuse if not redacted" precondition became "redact if not already redacted"). The real anti-bypass guarantee is the static lint (`scripts/lib/lint-stage-io.sh`) plus the fact that `route_to_model[_loop]` is the ONLY model-call path.
- **Stage-level enforcement:** ADR-013's tier assignment additionally reinforces this invariant — stages assigned T0 (`test`, `pr`, `deploy`, `validate`) MUST never emit LLM-bound text. The T0 designation is a semantic constraint enforced by code review and the manifest redaction requirement; any plugin wired into a T0 stage that calls the router is a bug surfaced by the redaction chokepoint and manifest validation. See [ADR-013](ADR-013-canonical-stage-list.md) §Tier assignment rationale.

### Scope manifest contract

The scope manifest is a fenced markdown block in `design.md` (or runtime equivalent). Format:

```markdown
## Scope

\`\`\`scope
+ path/to/included/dir/
+ path/to/specific/file.ts
- path/to/excluded/dir/
\`\`\`
```

Parsed in one line of awk. Humans edit visually; engine reads the fence content as the authoritative allowlist.

### Operator override (audit-trail required)

In rare cases an operator may need to disable redaction for a debug run. This requires BOTH:
1. `ZBUILD_SCOPE_OVERRIDE=1` env var.
2. A token file at `~/.zbuild/scope-override-token` containing the current pipeline's `run_id`.

The token file must be written by the operator manually each run (one-shot). The agent CANNOT self-grant the override. Every override emits a `redaction.refused.overridden` event with operator-identifying metadata.

## Consequences

**Good:**
- One place to audit. One place to test. One place to extend (when we add ANSI-strip-on-emit or PII detection).
- New prompt sites can't accidentally bypass.
- Failure mode (refuse-to-emit on missing manifest) is fail-closed by default.
- Operator override is observable in event log.

**Bad:**
- Plugin authors must always go through the helper, even for "obviously safe" prompts. Friction. Mitigation: the helper is one function call.
- Tests grep for raw model invocations; clever obfuscation (e.g., constructing the URL via variable substitution) could bypass. Accepted; we're guarding against accidents, not adversaries.

## Implementation Notes (Phase 0.5 — issue #291)

- **Chokepoint** lives at `core/redaction/scope-redaction.sh:34–158` (`apply_scope_redaction`). It refuses to emit when the scope manifest is missing/empty unless an explicit operator override (`ZBUILD_SCOPE_OVERRIDE=1` + token file matching `ZBUILD_RUN_ID`) is set, in which case it emits a `redaction.refused.overridden` audit event.
- **Router redaction by construction** (`core/router/route.sh`, `_route_ensure_redaction` / `_route_redact_prompt`) — as of ADR-043 the router redacts the prompt itself when a plugin has not already done so (detected via the per-stage most-recent-`redaction.applied` check), then routes. The former C6 precondition (`_route_check_precondition`) that *refused* dispatch is retired in favour of this. The `--skip-precondition` operator-override path is unchanged (fail-closed without a matching token); degenerate environments (no `run_id` / no events log) also stay fail-closed. Historic edge case **#289** (rescoped 2026-05-26) is subsumed: a run with no prior redaction is now redacted, not refused.
- **KEEPERS §C note correction:** legacy had 9 redaction seams; zBuild unifies all LLM-bound emission through this one chokepoint. The 9-seam framing in KEEPERS describes the *legacy* state.
- **Intake note:** `plugins/agent/intake/manifest.yaml` declares `requires.core: [redaction, event-bus, state]` but does not yet call `apply_scope_redaction` because intake doesn't emit LLM-bound text in Phase 0.5. Phase 1 intake-LLM wiring MUST invoke the chokepoint before any model call.
- **Test coverage:** `tests/unit/core-redaction-test.sh` exercises fail-closed behavior; `tests/mutation/scope-redaction-mutations.md` inverts the guard and confirms tests catch it.

## Amendment — Pattern 2 (`route_to_model_loop`) per-iter emit (issue #467, ADR-018)

`route_to_model_loop` (introduced by ADR-018 Pattern 2 via #467) emits a
`redaction.applied` event on EVERY iteration of the inner agent loop —
not just the initial call. This preserves C6 precondition ("LLM never
sees raw out-of-scope context") across multi-turn build runs.

The chokepoint invariant itself is unchanged: every LLM-bound text still
passes through `apply_scope_redaction`. The amendment only documents the
emission frequency, which is now per-iter rather than per-stage. See
ADR-018 §Pattern 2 for the loop semantics and ADR-015 §v6 for the
per-iter banner ordering.

## Amendment — C6 scoped per-stage for parallel-group safety (ADR-039)

The C6 precondition originally validated that the most-recent event **for the
`run_id`** was `redaction.applied`. That assumed serial stage execution. When
ADR-039 parallel stage-groups first ran (dogfood run
`20260629214235-33569`), all five `review_lenses` members failed C6: members
run concurrently and emit interleaved events to the SHARED run-level event log,
so a sibling member's `plugin.run.start` became the most-recent GLOBAL event
for the run before any one member emitted its own `redaction.applied`.

The fix scopes C6 **per-stage** without weakening the chokepoint invariant:

- `eb_emit_event` (`core/event-bus/event-bus.sh`) stamps a top-level `stage`
  field onto every event emitted while `ZBUILD_CURRENT_STAGE` is set. Each
  parallel member exports its own `ZBUILD_CURRENT_STAGE` inside its subshell
  (ADR-039 §3), so every event carries the stage/member that produced it.
  Stage-less emits (e.g. `pipeline.start`, template load) keep the canonical
  8-key envelope.
- `_route_check_precondition` (`core/router/route.sh`) now validates the
  most-recent event **for `(run_id, ZBUILD_CURRENT_STAGE)`** is
  `redaction.applied`. When no stage is set it falls back to the run-level
  check (unchanged behaviour for direct/bootstrap calls).

This is provably equivalent to the old check for serial stages (only one stage
is active at a time, so the most-recent for-stage event is the most-recent run
event) and makes each concurrent LLM member enforce ITS OWN redaction
independently. A member can NOT ride a sibling's `redaction.applied` — its own
stage's most-recent event must be the redaction. Covered by
`tests/integration/router-precondition-parallel-test.sh`.

## References

- [KEEPERS.md §C](../KEEPERS.md#section-c--reliability--safety-expanded) — redaction has 9 prompt seams; no wrapper today.
- `legacy/scripts/lib/helpers.sh:634-800` — original `_redact_paths_outside_scope` implementation (reference for the new chokepoint).
- `legacy/scripts/lib/pipeline-stages.sh:42` — scope-manifest extraction.
