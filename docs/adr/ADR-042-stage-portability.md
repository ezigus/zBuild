# ADR-042 — Stage portability: uniform stage→plugin resolution across flow constructs

**Status:** Accepted (2026-06-29)
**Amends:**
- ADR-001 (plugin contract — a stage's flow-name need not equal its manifest `id`; resolution is role-then-id everywhere)
- ADR-021 (pipeline cycle semantics — cycle members resolve role-then-id via the shared helper, not id-only)
- ADR-039 (parallel stage groups — parallel members resolve role-then-id via the shared helper, not id-only)
**Related:** ADR-027 (recursive-flow template format), ADR-040 (composable gate/lens taxonomy)

## Context

Stage→plugin resolution differed by *where the stage sat in the flow*. The leaf
(serial) dispatch path resolved a stage to its plugin by **role first, then id**
(ADR-001 role binding, with id-match as a backward-compat fallback). But the two
recursive constructs resolved differently:

- `cycle_dispatch_stage` (cycle members, ADR-021) resolved by manifest **`id`
  only** (`_find_plugin_for_stage`).
- `parallel_dispatch_stage` (parallel-group members, ADR-039) likewise resolved
  by manifest **`id` only**.

A stage whose plugin `id` ≠ its flow-name and that binds by **role** therefore
resolved on the leaf path but silently failed inside a cycle or parallel group:
`_find_plugin_for_stage` returned empty, the member was stamped `verdict=error`,
and the cycle/group aborted. This bit exactly the stages EPIC #1129 introduced:
the mechanical gates (`lint`→`lint-gate`, `coverage`→`coverage-gate`,
`mutation`→`mutation-gate`) packaged in the gate parallel group, and every lens
member (`lens-security`, `lens-performance`, … → `review-lens`) in the advisory
review parallel group (ADR-040). None of them could run where the template
placed them.

The goal is **plug-and-play stages**: any stage runs wherever it is placed —
serial, cycle member, or parallel-group member — with no resolution behavior
that depends on the surrounding flow construct.

## Decision

A single shared resolver, **`resolve_stage_plugin <stage> [plugins_root]`** in
`core/pipeline/dispatch.sh`, codifies the **role-then-id** rule and is adopted by
the cycle and parallel dispatch paths, bringing them to parity with the leaf
(serial) path — which already applied role-then-id via its own inline resolution
(`runner.sh`, the main-loop leaf branch: `resolve_plugin_for_role` first, then
`_find_plugin_for_stage`). Resolution is now uniform across all three constructs;
the leaf path keeps its existing inline logic (a candidate for later
consolidation onto this helper, out of scope here). The rule:

1. **Role first.** If template role data and the role resolver are present, the
   stage's declared roles (ADR-001) are resolved to a plugin — platform-specific
   then generic — first-match wins. Cycle/parallel members resolve a **single**
   plugin (they do not fan out).
2. **Id fallback.** If no role resolves (or no role is declared), fall back to
   manifest-`id` match (`_find_plugin_for_stage`) — the legacy behavior,
   preserved verbatim.

A stage's **flow-name need not equal its plugin `id`**. Role binding (ADR-001) is
authoritative; id-match exists only for backward compatibility with stages whose
name already equals their plugin id.

Convergence / blocking behavior is **declared per-stage, not inferred from
position** in the flow: whether a stage can block merge is a property of its
declaration (forward reference: ADR-040's gate-aggregator + the `convergence:`
marker, a sibling change), not of whether it happens to sit in a cycle or a
parallel group. Resolution and convergence are orthogonal concerns.

## Consequences

- Role-bound mechanical gates (`lint-gate`, `coverage-gate`, `mutation-gate`)
  and the advisory lens parallel group (all `review-lens`) now dispatch
  correctly inside cycle and parallel constructs — the failures EPIC #1129's
  decomposition surfaced are resolved at the resolution layer.
- **Zero regression** for stages that already resolved by id: when a stage's
  name equals its plugin id (or it declares no role), role resolution misses and
  the id fallback returns exactly what the old id-only path returned. This is
  verified by `tests/unit/stage-resolution-parity-test.sh` SPEC-3, which pins
  the previously-resolving stages to their unchanged targets, and SPEC-1/SPEC-2,
  which pin the baseline symptom and the fix.
- Stages become **composable across serial / cycle / parallel** placement — the
  plug-and-play property — without per-construct resolution code.
- The resolver is side-effect-free (echoes the plugin dir, returns 0/1); its
  role-unresolved diagnostic matches every other strategy path.

## Implementation Notes (issue #1171, Change A)

Landed in this PR — code, test, and ADRs together (not a text-only ADR):

- `core/pipeline/dispatch.sh` — new `resolve_stage_plugin <stage> [plugins_root]`:
  role-then-id, single first-match, side-effect-free (echoes the plugin dir,
  returns 0 on hit / 1 on miss). Mirrors the leaf path's platform-specific →
  generic role lookup, then falls back to `_find_plugin_for_stage` (id-match).
- `core/pipeline/runner.sh` — `cycle_dispatch_stage` and `parallel_dispatch_stage`
  now call `resolve_stage_plugin` instead of `_find_plugin_for_stage` (id-only).
- `tests/unit/stage-resolution-parity-test.sh` — pins the baseline symptom
  (SPEC-1: id-only returns empty for role-bound stages), the fix (SPEC-2: the 8
  role-bound gate/lens stages resolve), the zero-regression invariant (SPEC-3:
  previously-resolving stages unchanged), and the miss contract (SPEC-4: empty
  stdout + rc=1).

The leaf (serial) path keeps its existing inline role-then-id resolution; folding
it onto this shared helper is a candidate follow-up, deliberately out of scope to
keep this change zero-regression on the most-traveled path.

## References

- [ADR-001](ADR-001-plugin-contract.md) — plugin contract; role binding is the
  primary resolution key, flow-name ≠ manifest id permitted. **Amended.**
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) — cycle semantics; cycle members
  resolve via the shared role-then-id helper. **Amended.**
- [ADR-027](ADR-027-recursive-flow-template-format.md) — recursive-flow grammar
  that places stages in leaf / cycle / parallel constructs.
- [ADR-039](ADR-039-parallel-stage-groups.md) — parallel stage groups; parallel
  members resolve via the shared role-then-id helper. **Amended.**
- [ADR-040](ADR-040-composable-gate-lens-taxonomy.md) — the gate/lens
  decomposition whose role-bound stages this resolution fix makes runnable;
  per-stage `convergence:` declaration is the sibling change.
