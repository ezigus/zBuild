# ADR-045: Bounded Typed Backward-Route Primitive (rc=11 route_back)

**Status:** Accepted (#1217, keystone of the pipeline-correctness EPIC #1216)
**Date:** 2026-07-03
**Depends on:** ADR-021 (pipeline cycle semantics / rc table), ADR-027 (recursive flow template format / acyclicity), ADR-040 (composable gate/lens taxonomy — advisory stages never drive loops)
**Amends:** ADR-021 (adds rc=11 route_back to the terminal-rc table as a NON-halt class), ADR-027 (adds a carve-out to the membership-acyclicity contract for the bounded backward edge)

## Context

zBuild's pipeline is strictly **forward**: the runner walks
`_TPL_DISPATCH_UNITS[]` once, and cycles are the only re-entry mechanism —
each cycle re-runs *its own members* under a per-cycle `max_iterations`. There
is no way for a later unit to hand control back to an *earlier* unit. This is
correct for the common case, but it dead-ends the recurring failure mode the
EPIC targets: a stage self-certifies "done", a *later* stage discovers the work
was wrong (an acceptance-gate tautology rooted in a bad design, a plan that
can't actually be built), and the pipeline has no bounded, first-class way to
re-enter the *producing* stage to correct it. Teams either fail hard
(`member_terminal_failure`) or bolt on ad-hoc nested loops per scope.

The EPIC's principle: cross-stage correction is **ONE** bounded typed
backward-route — not nested loops per scope. This ADR is that keystone engine
primitive; issues #1218 (design-verify cycle) and #1220 (acceptance-gate
reporting) build on it, and #1219 wires the acceptance→design route.

## Decision

Add a cycle-level template attribute `route_back`, a sibling of
`exit_when`/`abort_when`, that re-enters a **named earlier** dispatch unit,
bounded by a **configurable global budget (default 2 total passes = exactly one
jump back)**.

### Grammar (template.sh, new-shape parser)

```yaml
some_cycle:
  type: cycle
  flow: [build, test]
  exit_when:  { stage: test, field: verdict, op: eq, value: pass }
  route_back:
    to: design                # a STRICTLY-earlier dispatch unit (or a member of one)
    when: { stage: acceptance, field: verdict, op: eq, value: tautology }
    max: 2                     # per-edge cap (subordinate to the global budget)
```

Parsed beside `abort_when` into `_TPL_CYCLE_ROUTE_BACK_{TO,STAGE,FIELD,OP,VALUE,MAX}_<cid>`.
An absent block ⇒ empty vars ⇒ the primitive is **inert** (forward-only,
byte-identical behavior).

### Verdict — rc=11, reason `route_back` (NOT a halt)

The cycle rc table gains `11 = route_back`. Unlike the halt classes
(4/5/6/7/8/9/10/130/143) it is a **CONTINUE-with-bounded-REWIND** class and is
deliberately **absent** from the runner halt-case. The orchestrator only
reclassifies a **correctable** non-clean terminal — `term_rc ∈ {2, 8}`
(unconverged / member_terminal_failure) — into rc=11 when the `route_back`
predicate matches. A clean converge (0), `cycle_abort` (6), `blocked` (5),
`blocked_on_scope` (7), `config_invalid` (4) and signals (130/143) **never**
reroute. On reclassification the orchestrator stashes the by-severity
**fallback rc** and the **target** for the runner, then returns 11 (a nested
inner cycle's rc=11 propagates outward — only the runner owns dispatch-unit
rewind).

### Runner — bounded rewind + global budget

The dispatch loop is index-form so rc=11 can rewind. On rc=11 the runner
resolves the target to a dispatch-unit index; if it is **strictly earlier** AND
both the global budget and the edge's own `max` cap remain, it emits
`cycle.route_back`, rewinds the index and replays forward. Otherwise it
restores the stashed fallback rc and falls through to the normal by-severity
terminal handling (**no rewind**).

- **Global budget is authoritative + enforced.**
  `_RUNNER_ROUTE_BACK_BUDGET = ${ZBUILD_ROUTE_BACK_BUDGET:-2}` is the TOTAL
  number of forward passes over the routed segment across the whole run
  (initial pass counts as 1; default 2 = exactly one jump back). This global
  total is the **hard ceiling**.
- **Per-edge `max` is a subordinate local cap.** An edge fires at most its own
  `max` times, but the global total always wins. Budget or cap exhausted → fall
  through to terminal, no rewind.
- Seq labels re-increment monotonically on replay (a replayed stage is a new
  time-ordered event); the `cycle.route_back` event provides legibility.

### Acyclicity carve-out (ADR-027)

The `route_back` edge lives in a **separate** var, not in membership flow, so
`_tpl_validate_flow_acyclic` (the ADR-027 membership-cycle walk) is
**unchanged** and still rejects genuine unbounded reference cycles. A new
`_tpl_validate_route_back` permits the backward edge **iff** `to` resolves to a
strictly-earlier dispatch unit AND `max` is a finite positive int; it rejects
forward/self targets and empty/zero/non-numeric `max` (an unbounded backward
route). The edge is permitted precisely *because* it is budget-bounded.

## Consequences

- One cross-stage correction mechanism, engine-level and repo-agnostic (verdict
  + target-unit + global counter; no plugin/language/path assumptions).
- `cycle.route_back` is a new emitted event (registered in
  `config/event-schema.json`).
- Forward-only pipelines are unaffected: with no `route_back` declared the
  orchestrator never yields rc=11 and the runner loop is behaviorally identical.
- Interactions: on budget-exhausted fall-through, `fallback_rc=2` flows into the
  existing unconverged branch (so `on_max=continue` is honored) and
  `fallback_rc=8` into the rc=8 halt (status=failed). Advisory stages never
  drive a route_back (ADR-040 holds).

## Implementation Notes

- **Grammar (template.sh, new-shape parser only).** `route_back` is parsed
  alongside `abort_when` in `_tpl_translate_new_shape` (`in_route_back` +
  nested `in_rb_when` for the `when:` predicate) and emitted as an
  `RB|<cid>|<to>|<stage>|<field>|<op>|<value>|<max>` row. The loader `RB)` case
  exports `_TPL_CYCLE_ROUTE_BACK_{TO,STAGE,FIELD,OP,VALUE,MAX}_<safe>`. The v2
  `stages:` parser does NOT support `route_back` — matching its sibling
  `abort_when`, which is also new-shape-only. Absent block ⇒ empty vars ⇒ inert.
- **Validation.** `_tpl_validate_route_back` runs from `load_template` AFTER
  `_tpl_build_dispatch_units` (so `_TPL_DISPATCH_UNITS[]` ordering is available)
  and AFTER `_tpl_validate_flow_acyclic`. `_tpl_resolve_unit_index` (template.sh)
  mirrors `_runner_resolve_unit_index` (runner.sh) so load-time and run-time
  agree on unit ordering and membership resolution.
- **Orchestrator.** `_cycle_check_route_back` mirrors `_cycle_check_abort_when`
  (reads the per-cycle predicate via `_CYCLE_TRAP_CYCLE_ID`, emits the
  `route_back` predicate event). The reroute guard sits AFTER `term_rc` is
  computed and BEFORE the single atomic state write; the fallback rc + target
  are assigned as GLOBALS (no `local`) and reset per run at
  `cycle_orchestrator_run` entry so a prior cycle's hand-off can't leak.
- **Runner.** The dispatch loop is index-form (`for (( _ui... ))`). The rc=11
  branch sits after the orchestrator call and before the terminal-rc backstop;
  on rewind it `continue`s (setting `_ui = target - 1` so the loop increment
  lands on the target) and does NOT run the backstop. `_RUNNER_ROUTE_BACK_PASSES`
  starts at 1; a per-edge counter `_RUNNER_ROUTE_BACK_EDGE_<cid>` enforces the
  subordinate cap. rc=11 is intentionally excluded from the halt-case condition.
- **Events.** `cycle.route_back` is registered in `config/event-schema.json`
  (the emitted-⊆-known_types coverage test enforces this). No golden regen was
  required (`cq-event-types.golden` enumerates only `cq.*`; the envelope golden
  is a single fixed pipeline.start envelope).

## References

- Issue #1217 (this ADR) — keystone engine primitive.
- EPIC #1216 — pipeline correctness (local verify-cycles + ONE bounded backward-route).
- ADR-021 — cycle semantics / terminal-rc table (amended: rc=11 added).
- ADR-027 — recursive flow format / acyclicity (amended: route_back carve-out).
- ADR-040 — advisory stages never drive loops.
