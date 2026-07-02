# ADR-043: Redaction by Construction in the Model-Call Path

**Status:** Accepted
**Date:** 2026-07-02

## Context

[ADR-004](ADR-004-redaction-chokepoint.md) established `apply_scope_redaction`
as the single function that emits LLM-bound text, and made the router enforce a
**C6 precondition**: `route_to_model` refused to dispatch unless the most-recent
event for the `(run_id, stage)` was already `redaction.applied`. That split
responsibility across **two actors**:

1. **Each plugin** (~8 of them, ~17 call sites) sourced `scope-redaction.sh`,
   called `apply_scope_redaction` itself, checked its result, and read back the
   redacted file.
2. **The router** only *verified* that a plugin had done so, and hard-refused
   (rc=2) otherwise.

This is fragile. Any prompt-emitting path that forgets to redact — a new stage,
an early return, an empty-evidence guard — bypasses redaction and the router
hard-refuses. It has recurred. The triggering instance: the #952 dogfood reached
`review_lenses` with a build that converged on an **empty diff**;
`review-lens/plugin.sh` only redacted `if [[ -s "$evidence" ]]`, so with empty
evidence it skipped redaction, called `route_to_model` with no `redaction.applied`,
and C6 (correctly, fail-closed) refused all five lenses.

Meanwhile `route_to_model_loop` (ADR-018 Pattern 2) **already redacts
internally** on every iteration — so the pattern that makes redaction automatic
already existed in the codebase; only single-shot `route_to_model` lacked it.

## Decision

**The router owns the redaction step. Redaction is inseparable from the model
call — you cannot send text to the model without it.**

`route_to_model` (single-shot) redacts its prompt internally, exactly as
`route_to_model_loop` already does, via a shared helper `_route_redact_prompt`.
The former C6 precondition inverts:

> **from** "refuse if the prompt was not already redacted"
> **to**   "redact the prompt if it was not already redacted".

### Backward compatibility — redact only if the caller hasn't

The change is backward-compatible with the plugins that still self-redact. Before
the model call, `_route_ensure_redaction`:

- **Already redacted?** If the most-recent event for `(run_id, ZBUILD_CURRENT_STAGE)`
  is `redaction.applied` (a plugin redacted), proceed unchanged — **no
  re-redaction, no double emit** (per-stage dedup, ADR-039 §3).
- **Not redacted?** The router redacts now: write the prompt to a temp file,
  resolve the scope manifest + allowlist, call `apply_scope_redaction`, emit the
  canonical `redaction.applied`, and hand `_route_call_claude` the redacted text.

This lets ADR-043 land alongside the (now redundant) plugin redaction calls; a
follow-up sweep removes them.

### Scope plumbing

The router needs the manifest + allowlist without a plugin passing them. The
runner (`core/pipeline/runner.sh`) exports, for **every** stage:

- `ZBUILD_SCOPE_MANIFEST` — the fixed `${ZBUILD_STATE_DIR}/scope-manifest.md`
  (one place, set alongside `ZBUILD_STATE_DIR`).
- `ZBUILD_SCOPE_ALLOWLIST` — derived per-stage from `plan.files[]`
  (`_runner_export_scope_allowlist`). Empty before `plan.json` exists; purely
  **additive** to the manifest's own `+ path` allowlist, so an empty value is
  safe (the manifest is the base allowlist).

### Fail-closed preserved

Fail-closed semantics are unchanged (and verified live):

- A **configured-but-missing/empty** manifest → `apply_scope_redaction` emits
  `redaction.refused` (rc1) and the router **refuses the call** (rc=2) — exactly
  as C6 did.
- **Applied-even-if-empty** (blank prompt + present manifest) → `redaction.applied`
  → proceed.
- The `--skip-precondition` operator override (`ZBUILD_SCOPE_OVERRIDE=1` + token)
  is unchanged and audited.
- **Degenerate environments** (no `run_id` / no events log) stay fail-closed —
  the router cannot scope or emit reliably there.
- When **no** manifest is configured at all (unit-test / bootstrap), the shared
  helper falls back to a passthrough copy plus a `redaction.applied` stub
  (`scope_hash=router-passthrough`), so the by-construction invariant holds even
  without a manifest. In production the runner always sets the manifest, so this
  path is test-only.

### The real anti-bypass guarantee

C6-as-a-gate is retired as the *primary* mechanism. The guarantee that nothing
reaches the model unredacted now rests on:

1. **Construction** — `route_to_model[_loop]` redacts, and it is the ONLY
   model-call path.
2. **Static lint** — `scripts/lib/lint-stage-io.sh` + the redaction-chokepoint
   scanner (`tests/unit/redaction-chokepoint-test.sh`) fail CI if any code
   invokes `claude`/`curl anthropic` outside `core/router` / `core/redaction`.
3. **Manifest** — `kind: agent` plugins still declare `requires.core: [redaction]`
   (redaction is still required — just centrally applied).

## Consequences

**Good:**
- **Zero-effort authoring.** A new LLM stage sources `route.sh` and calls
  `route_to_model "$tier" "$prompt"`. No `scope-redaction.sh` source, no
  `apply_scope_redaction` call, no read-back, no `redaction.applied` bookkeeping.
- Single-shot and loop now share one redaction path (`_route_redact_prompt`).
- The recurring empty-evidence / new-stage bypass class is eliminated.

**Bad / watch:**
- Highest-blast-radius change: it touches every LLM stage's call path. Mitigated
  by the full chokepoint test-suite and the static lint invariant.
- The allowlist env channel is the one genuinely per-stage value; if
  runner→env→router plumbing regresses, plan/design/build redaction *scope*
  narrows (over-redaction, fail-safe) but does not fail open.

## Implementation Notes (Issue A1 — redaction by construction)

- `core/router/route.sh`: `_route_redact_prompt` (shared), `_route_ensure_redaction`
  (replaces `_route_check_precondition`), wired into `route_to_model`; the loop's
  per-iteration redaction now calls the same helper.
- `core/pipeline/runner.sh`: exports `ZBUILD_SCOPE_MANIFEST` +
  `ZBUILD_SCOPE_ALLOWLIST` (`_runner_export_scope_allowlist`).
- Plugins keep their `apply_scope_redaction` calls for now (removed in a
  follow-up); the dedup keeps them working with no double redaction.

## References

- [ADR-004](ADR-004-redaction-chokepoint.md) — the chokepoint this inverts.
- [ADR-018](ADR-018-stage-invocation-modes.md) — `route_to_model_loop` per-iter emit (the pattern mirrored).
- [ADR-039](ADR-039-parallel-stage-groups.md) — per-stage event scoping (the dedup basis).
- `core/router/route.sh`, `core/pipeline/runner.sh`, `core/redaction/scope-redaction.sh`.
- Tests: `tests/integration/router-precondition-test.sh`,
  `tests/integration/router-precondition-parallel-test.sh`,
  `tests/integration/core-router-route-test.sh`, `core/router/tests/route-unit-test.sh`.
