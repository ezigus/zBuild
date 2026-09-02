# ADR-040 — Composable gate / lens taxonomy (the convergence-path invariant)

**Status:** Accepted (2026-06-27)
**Related** — dispositions below are **PLANNED** (declared here, executed in later issues of EPIC #1129 alongside the code that lands the decomposition); **this PR edits no existing ADR**:
- evolve-planned: ADR-037 (the objective-gate *monolith* decomposes into many first-class `kind: tool` gate stages + a gate-aggregator; ADR-037's two-layer invariant is preserved and made machine-enforced)
- supersede-planned: ADR-038 (its single-stage packaging of the lens fan-out is replaced by composable `kind: agent` lens stages + a review-aggregator; the lens *content* and evidence-fed contract are kept)
- amend-planned: ADR-013 (canonical-stage list — gate/lens stages are addressed by stage id; the gate-aggregator + review-aggregator are the canonical convergence-bearing rows)
- amend-planned: ADR-019 (fail-closed re-expressed as "a failing mechanical gate fails the gate-aggregator")
- depends: ADR-039 (parallel stage groups) — gates and lenses are packaged as `type: parallel` groups
- peer: ADR-039; EPIC #1129
- applied-by: ADR-046 (#1218) — `design-gate` is a new `convergence: gate` T0 member of
  `simple.yaml`'s `design_verify_cycle`; its sibling `impact` is advisory BY PLACEMENT
  (a lone top-level stage, no marker, off the convergence path). The typed-aggregator
  preflight rule (A) is satisfied by binding `exit_when` directly to the single gate member.
- extended-by: ADR-047 (#1277) — §7's "discovered, not hardcoded" marker principle is
  extended from must-pass-set discovery to the verdict-channel (§3) and capability-flag (§4)
  metadata, and to fail-closed membership/order preflights (§5), so no mechanic names a stage.
**Issue:** #1143 (EPIC #1129, D1)

## Context

ADR-037 drew the load-bearing line: **mechanical, deterministic, no-LLM checks may hard-block merge;
semantic, LLM judgment is advisory and never blocks.** Its §3 stated the invariant as prose — "No
objective gate is an LLM; no semantic lens hard-blocks merge" — and ADR-038 packaged *all* the semantic
judgment into one `review` stage.

ADR-037 left the objective layer as a conceptual *set* of gates but did not give each gate a first-class
identity, and ADR-038 bundled the lenses inside a single stage's hand-rolled fan-out. Two gaps follow:

- **The invariant is asserted by hand, per stage, not enforced by construction.** Today a test reads one
  stage's body and checks "does this objective-gate stage call the router?" (ADR-037 §3). That is a
  spot-check, not a structural guarantee. As the gate set grows and lenses multiply, nothing *mechanical*
  stops a future author from wiring an LLM stage into the must-pass set or into an `exit_when`, quietly
  re-merging the two layers ADR-037 split — the exact BLUR ADR-037 exists to prevent. MEMORY's recurring
  lesson is that "LLM review verdict advisory, mechanical acceptance-gate authoritative" only holds if it
  is enforced, not documented.

- **The two layers are not yet *composable* in the template.** ADR-037's gates and ADR-038's lenses want
  to be many small stages that run concurrently and aggregate (ADR-039), but their identities, their
  `kind`, and the rule binding `kind` to "may-block vs advisory" are not codified. Without that taxonomy,
  the decomposition has no schema and the invariant has no field to check.

ADR-039 supplies the missing dispatch + aggregation machinery (`type: parallel` groups,
`aggregate: all_pass` / `advisory`, the group-verdict). ADR-040 supplies the **taxonomy** that classifies
stages into the two kinds and the **machine-enforced invariant** that keeps them from re-merging.

## Decision

Define a two-class stage taxonomy and a machine-checked invariant that binds class → blocking authority.

### 1. Gate stages — `kind: tool`, T0, no-LLM, may block

A **gate** is a mechanical check stage with `kind: tool` (ADR-001 plugin kinds), tier **T0**, and **no
router/LLM call** (ADR-037 §3). The gate set is ADR-037's objective layer, now each a first-class stage:
`gate_suite` (full suite green), `gate_lint`, `gate_negctl` (baseline-fail), `gate_reachability`
(ablation), `gate_shape_floor` (golden/stage-shape), `gate_coverage` (statement floor),
`gate_scope` (scope-adherence), and `gate_typecheck` (ADR-033 promoted). Each is deterministic,
auditable, and gameable only by actually satisfying it.

### 2. Gate-aggregator → `exit_when` (the only thing that can block)

The gate stages are packaged as an ADR-039 `type: parallel` group with `aggregate: all_pass`. The
**gate-aggregator** collapses the member verdicts to one group verdict (`pass` iff every gate passed),
and the surrounding `flow:`'s `exit_when` / `blocking` evaluates against *that* group verdict. The
gate-aggregator group is the **only** convergence-bearing, merge-blocking construct in the pipeline. This
is where ADR-019's fail-closed lives now: a non-green suite (or any failing mechanical gate) fails the
gate-aggregator, halting before the semantic layer runs.

### 3. Lens stages — `kind: agent`, LLM, advisory only

A **lens** is a semantic judgment stage with `kind: agent` (LLM-backed), fed **distinct mechanical
evidence** per ADR-038 §2 (a lens reads a *different artifact*, not a different prompt over the same
diff). The lens set is ADR-038's rehomed cq + persona content (security / logic / integration /
completeness / error-handling / performance / edge-case, the persona plugins, design-decision-honoring,
assertion-integrity). Each lens is now a first-class stage, not a sub-routine of one review stage.

### 4. Review-aggregator → advisory report (never blocks)

The lens stages are packaged as an ADR-039 `type: parallel` group with `aggregate: advisory`. The
**review-aggregator** merges + de-dups (file + category + proximity) the member findings into the
ADR-038 merge-readiness report. The group verdict is **always** advisory — it never aggregates to a
blocking `fail`, never appears in any `exit_when`, never coerces an `approve`/`request_changes`/`block`
mutation. Escalation to a human PR is decided by ADR-037's `merge_policy` reading the report's
top-severity findings — the report is the *input* to that policy, not a gate.

**Amendment (2026-08-31, #1986 — closes #1898): advisory output DOES reach
downstream prompts.**

#1898 asked whether an advisory stage's findings should feed the build loop, and
required a recorded decision rather than an inherited default. The decision:
**every stage publishes a summary and every following stage ingests them,
advisory included.**

This does not weaken §5. That invariant governs whether a stage may **block** —
whether it can appear in a must-pass set or an `exit_when` predicate — and is
checked against template *structure*. Injecting a stage's text into a prompt
places it on no convergence path. The B5 no-LLM-on-the-convergence-path
invariant is untouched: advisory stages still never gate, never aggregate to a
blocking verdict, and never appear in a predicate.

What changes is the *reading* side, which §4 governs. The argument that settled
it: review finds real defects (#1707 measured 17 lens findings, 1 high, on one
run), and a build re-running without ever seeing them lets the same defect class
survive several iterations, with a human only learning at PR time. The
counter-argument — that feeding advisory findings into build lets a non-blocking
signal shape the code — is answered by the separation this ADR already draws:
shaping the code is what build does with *all* its context, and nothing here
lets an advisory stage decide whether the work converges.

**Duplication is prevented by construction.** An aggregator declares the roster
it covers (`aggregates: <convergence-marker>`); the engine ships only the
aggregate and suppresses those members' own summaries. An aggregator that
suppresses a roster must itself publish a summary — deleting a roster's findings
and contributing nothing in their place is a silent loss, and is guarded by a
tree-wide test rather than left to review.

**Amendment (2026-08-31, #1988): the aggregator stops rendering; each gate
publishes its own detail.**

The gate-aggregator did three jobs. Two are irreplaceable: it produces the ONE
convergence verdict §5 requires a cycle to bind to, and it rolls up the declared
fault class (ADR-061). The third — rendering `gate-feedback.md` and
`design-feedback.md` — existed only because it was the sole path for gate detail
to reach a prompt: five gates declared nothing but a result JSON.

ADR-055 §9 made another path, so each gate now publishes its own detail as a
`summary: true` output and speaks for itself. Authoring prose *about design* was
never this stage's business — it relays a fault class each gate declares; it
does not decide what design ought to read.

Two consequences, both structural rather than stylistic:

- The aggregator also stops declaring `aggregates: gate`. It publishes no text,
  so covering the roster would suppress the members and ship an aggregate
  containing nothing.
- The routed/residual **partition disappears as a concept**. It existed because
  build read a *partial* payload and had to be told the remainder was "handled
  elsewhere". With every failing gate publishing its own finding there is no
  partial view to caveat. The property #1757 established — that a routed gate
  never takes build-fixable findings with it — survives as: every failing gate
  is named in the aggregate and publishes its own detail.

### 5. The convergence-path invariant (machine-enforced)

> **No `advisory` stage may appear in the must-pass set or in any `exit_when` predicate.**
> Equivalently: every stage on a merge-blocking convergence path is declared `convergence: gate`
> (mechanical, no model.route); every `convergence: advisory` stage aggregates `advisory` and is
> reachable only from a non-blocking group.

This is ADR-037 §3's prose invariant promoted to a **structural, checkable** property of the resolved
template. **The discriminator is the `convergence:` marker (see §7), not `kind:`** — the original
`kind:`-based phrasing mis-classified `acceptance-gate`, which is `kind: agent` (it is dispatched like an
agent stage) yet wholly mechanical (it shells negctl + reachability, no model.route call) and is a
legitimate must-pass gate. A validator walks the resolved flow and fails the template if:

- any `exit_when` / `abort_when` predicate references a stage (or a parallel group) that transitively
  contains a member that is **not** `convergence: gate` (i.e. `convergence: advisory`, or an
  undeclared-marker stage that is `kind: agent` — fail-closed: an undeclared LLM stage may not gate); or
- any `aggregate: all_pass` (potentially-blocking) parallel group contains such a member; or
- any stage with a router/LLM call (that is not a declared `convergence: gate`) is reachable on a path
  that can block merge.

Because the invariant is checked against template *structure* (marker + aggregate-policy + predicate
targets), it is un-gameable by prompt wording — it does not read what a stage *does*, it reads where a
stage *sits* in the convergence graph. This closes the "future author quietly re-merges the layers" gap
that the per-stage spot-check (ADR-037 §3) could not.

**Note (Phase 2, 2026-07-01) — per-member `disposition` refines gate blocking.** A `convergence: gate`
member's `verdict: fail` no longer unconditionally blocks convergence: the gate-aggregator reads the
generic `disposition` field (ADR-021 member-disposition contract) the member wrote alongside its verdict.
`disposition: advisory` (e.g. an infra flake such as a negctl/reachability timeout) is EXCLUDED from the
aggregator's fail set — it is a non-blocking failure, so a flaky sandbox never blocks merge. `recoverable`
and `terminal` (and an ABSENT disposition — fail-closed) stay blocking; `recoverable` additionally drives
another build iteration via the gate→build feedback edge. This does NOT weaken §5: `disposition` demotes a
gate's *failure* to non-blocking on a per-run basis; it never places an `advisory`-marked STAGE on a
convergence path. The structural invariant (marker + predicate targets) is unchanged.

### 6. Composability (boundary)

- Gates and lenses are ordinary ADR-039 parallel-group members and ordinary ADR-001 plugins; adding a
  gate means writing a `kind: tool` T0 stage and listing its id in the gate group's `flow:`; adding a
  lens means writing a `kind: agent` stage (declaring its evidence input per ADR-038 §2) and listing it
  in the lens group's `flow:`. No orchestration code changes per gate/lens.
- The `merge_policy` knob (ADR-037 §4) is unchanged: it reads the review-aggregator's report and the
  gate-aggregator's green to decide auto-merge / escalate / manual.
- ADR-020 inter-stage data contract is unchanged: gates and lenses declare their evidence inputs via
  manifests; lenses do not feed each other (they parallelize per ADR-039 §5).

### 7. The `convergence:` marker, roster-driven aggregation, and consolidated feedback (B1/B2, #1129)

**Canonical marker.** Every gate/lens manifest declares a top-level `convergence:` field (ADR-001):

- `convergence: gate` — mechanical, **blocks** convergence (in the must-pass set). May be `kind: tool`
  OR `kind: agent` (e.g. `acceptance-gate`): the marker, not `kind:`, is the authoritative
  mechanical-vs-advisory discriminator (it supersedes the §5 `kind:`-inference).
- `convergence: advisory` — **never** blocks; must not sit on a must-pass / `exit_when` path (lenses,
  review-aggregator).
- *absent* — not a convergence gate; excluded from the must-pass set (work stages, e.g. `build`).

The gate-aggregator itself omits the marker (it is the collector, not a member of its own set).

**Roster-driven aggregation.** The gate-aggregator's must-pass set is **discovered at runtime** from the
cycle members whose manifest declares `convergence: gate` (excluding itself and any advisory/absent
member) — there is **no hardcoded gate list**. It learns the cycle from `ZBUILD_CYCLE_ID` +
`_TPL_CYCLE_STAGES_<id>`, resolves each member's manifest (by id, else by role binding), and reads its
`convergence:` marker + result-artifact filename (`provides.artifact_type`). Adding/removing a gate from
a cycle's `flow:` changes the must-pass set with **no edit to the aggregator**. When no cycle is in scope
(e.g. the aggregator invoked standalone with result files but no cycle env), it falls back to a fixed
legacy set — regression safety, fail-closed (a roster that resolves to zero gates also falls back rather
than vacuously passing).

**Consolidated gate→build feedback.** The aggregator is the **single collector** of failure detail: on
`verdict=fail` it merges every failing gate's actionable detail (failing tests, acceptance-coverage gaps,
secret-scan hits, …) into one `gate-feedback.md` (a `required: false` manifest output). A cycle wires ONE
`gate-aggregator → build` feedback edge (build input `prior_gate_feedback`, `source: cycle_feedback`),
replacing the prior per-gate `test → build` / `acceptance-gate → build` edges, so the next build
iteration sees the full failure set in one place and the `build_test_cycle` self-heals.

## Consequences

- ADR-037's invariant stops being an honor-system spot-check and becomes a structural property the
  template validator enforces — the two layers cannot silently re-merge.
- The objective-gate monolith and the single review stage both dissolve into composable, individually
  testable stages; a gate or lens is added/removed by editing a parallel group's `flow:`, not by
  surgery on a 900-line shared plugin (the ADR-038 packaging this supersedes).
- Exactly one construct can block merge (the `all_pass` gate-aggregator); exactly one construct produces
  advisory judgment (the `advisory` review-aggregator). The blocking authority is concentrated, auditable,
  and LLM-free by validated construction.
- ADR-019 fail-closed survives, re-expressed as "a failing mechanical gate fails the gate-aggregator,"
  with no verdict coercion anywhere.
- New cost surface: each lens is now its own stage/dispatch. ADR-039's bounded FIFO pool caps the
  concurrency; per-lens model/tier and cost bounds are router config (ADR-017), out of scope here.

## Implementation Notes (EPIC #1129, planned)

### Phase 1 — typed, preflight-enforced aggregators (issue #1177)

The `convergence:` manifest marker is canonical and IS the aggregator/gate TYPE: `gate` = blocking
convergence (drives a cycle's `exit_when`), `advisory` = non-blocking review. Aggregators stay
EXPLICITLY named in the template — nothing is auto-injected; the preflight only asserts the named
wiring is present and type-correct.

- `gate-aggregator` now declares `convergence: gate` (symmetric with `review-aggregator`'s
  `convergence: advisory`), making it the named gate-typed convergence aggregator. It is still excluded
  from its own roster by id (`_ga_build_roster` never aggregates self), so the marker changes nothing
  about must-pass discovery.
- The `aggregate:` group declaration is wired through the runtime parser (see ADR-039 §Phase 1):
  `core/pipeline/template.sh` exports `_TPL_PARALLEL_AGGREGATE_<id>`.
- `core/pipeline/contract-validator.sh` (`_contract_validate_pipeline`), MIRRORED in
  `scripts/lib/lint-contract.sh` for CI parity, FAILS LOUD when: **(A)** a cycle's `exit_when.stage`
  resolves to a convergence-marked stage that is `advisory` or not a cycle member (untyped targets are
  legacy and NOT retro-checked); **(B)** a parallel group declaring `aggregate: advisory` has no
  explicit, non-member `convergence: advisory` aggregator stage. Blocking parallel groups converge via
  their own `exit_when` predicate (the §5 path guard / check (A)) and need no separate aggregator stage.
  Marker resolution is id-first then by `provides.role` — the same resolution the roster-driven
  gate-aggregator uses. Tests: `tests/integration/preflight-contract-templates-test.sh`,
  `tests/unit/lint-contract-convergence-test.sh`, `tests/unit/core-pipeline-template-parallel-test.sh`.

The original ADR PR (issue #1143, D1) authored the ADR text only — no code/template/test changes beyond
the two new ADR files. The taxonomy + invariant landed in later EPIC #1129 issues (the Phase 1 section
above, issue #1177, is the typed-aggregator preflight), in this order:

- **Gate decomposition** — split ADR-037's objective-gate layer into first-class `kind: tool` T0 gate
  stages and package them as an ADR-039 `aggregate: all_pass` parallel group with the gate-aggregator
  emitting the only merge-blocking group verdict. This **evolves ADR-037** (monolith → decomposed gates)
  and re-expresses **ADR-019** fail-closed.
- **Lens decomposition** — split ADR-038's single review stage into first-class `kind: agent` lens
  stages (each declaring its evidence input per ADR-038 §2) packaged as an ADR-039 `aggregate: advisory`
  parallel group with the review-aggregator emitting the merge-readiness report. This **supersedes
  ADR-038's single-stage packaging** while keeping its lens content + evidence-fed contract.
- **Invariant enforcement** — the template validator implements §5: walk the resolved flow, fail any
  template where a `kind: agent` stage is reachable on a merge-blocking path (in an `all_pass` group, or
  referenced by an `exit_when`/`abort_when`). This promotes **ADR-037 §3** from a per-stage spot-check to
  a structural check and is the load-bearing new test.
- **Canonical taxonomy** — **amend ADR-013** so gate/lens stages are addressed by stage id and the
  gate-aggregator + review-aggregator are the canonical convergence-bearing rows.

Ordering guard: ADR-039's `type: parallel` construct + the §5 invariant validator MUST be live before any
template adopts the decomposed gate/lens groups, or a decomposed flow could wire an LLM lens onto a
blocking path with nothing to catch it — re-opening the ADR-037 BLUR this ADR exists to prevent
structurally.

## References

- [ADR-037](ADR-037-objective-gates-vs-semantic-judgment.md) — objective gates vs. semantic judgment;
  its two-layer split + §3 invariant. **Evolve-planned** (monolith → decomposed gates; §3 invariant made
  machine-enforced).
- [ADR-038](ADR-038-adversarial-multilens-review-report.md) — adversarial multi-lens review report; its
  lens content + evidence-fed contract are kept, its single-stage packaging **superseded-planned**.
- [ADR-039](ADR-039-parallel-stage-groups.md) — parallel stage groups; gates and lenses are packaged as
  `type: parallel` groups (`all_pass` for gates, `advisory` for lenses). Dependency; peer in EPIC #1129.
- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list; gate/lens stages by id, aggregators
  are the convergence-bearing rows. **Amend-planned**.
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — fail-closed; re-expressed as a failing
  mechanical gate failing the gate-aggregator. **Amend-planned**.
- [ADR-001](ADR-001-plugin-contract.md) — plugin contract; `kind: tool` vs `kind: agent` is the
  taxonomy's discriminator.
- [ADR-033](ADR-033-compile-typecheck-gate.md) — typecheck gate, promoted into the gate set as
  `gate_typecheck` (per ADR-037 §6).
- [ADR-017](ADR-017-per-stage-router-config.md) — per-stage router config; per-lens model/tier + cost
  bounds live here, out of scope for the taxonomy.
- Issue #1143 (EPIC #1129, D1) — this ADR text.

## Amendment (#1219, 2026-07-04) — the gate-aggregator gains a ROUTE verdict

The gate-aggregator remains the **single convergence authority** (§5) — it still collapses the
must-pass roster into ONE verdict and is the only merge-blocking construct. #1219 adds a third
verdict class alongside `pass` / `fail`: **`route_<target>`** (concretely `route_design`).

Roster-driven, no plugin vocabulary: after computing the failed gates, the aggregator reads each
**failed** gate's generic `route_target` scalar (first non-empty wins) and, when present, emits
`verdict = route_<target>` and mirrors `route_target` into `gate-aggregator-result.json`. Because
`route_<target> != pass`, the cycle `exit_when` never falsely converges and `merge` (verdict != pass
→ PR path) never auto-merges — the bounded rewind is owned by the runner (ADR-045), not by merge.
On a route verdict the aggregator also writes a FOCUSED `design-feedback.md` (the design-rooted
gates' detail) instead of the build-facing `gate-feedback.md`, keeping it the single consolidator of
failure detail (§2). The B5 no-LLM-on-convergence-path invariant is untouched (the aggregator is T0).

This is additive: a roster with no `route_target` on any failed gate behaves exactly as before
(`pass`/`fail`), so `standard.yaml` and every existing gate-aggregator test are unchanged. See
ADR-045 (the route_back edge that consumes `route_design`) and ADR-036 (the acceptance-gate that
produces `route_target: design` on a tautology).

## Amendment (#2039, 2026-09-02) — what makes a stage admissible on a convergence path

**Problem.** §5 above states the invariant as *mechanical vs. model*: every
merge-blocking stage is `convergence: gate` — "mechanical, no model.route". But
§5's own justification is a different property:

> it does not read what a stage *does*, it reads where a stage *sits* in the
> convergence graph … un-gameable by prompt wording

**Un-gameability is the property. Mechanical-ness was a proxy for it** — a good
one, and the only one available when §5 was written, because every model-judged
stage then in existence read the artifact it was grading. A review lens reads the
change and judges its quality; the thing being graded is authored by the thing
being judged, so it can be talked into a verdict. That is what §5 closed, and it
stays closed.

But the proxy and the property came apart once a stage existed whose inputs are
**fixed and upstream-authored**. `spec-correspondence` (#2034) sees one SPEC
sentence — written by design, before any code — and one assertion. It never sees
the diff, and at its position in the cycle the implementation for that iteration
does not exist yet. Build's only lever on it is the assertion text, and the only
way to move that verdict toward `corresponds` is to make the assertion genuinely
correspond. **That is compliance, not gaming.**

**Decision.** A stage may sit on a merge-blocking convergence path when it is
either:

- **(a) mechanical** — no `model.route` call, as before; or
- **(b) model-judged over fixed, upstream-authored inputs, with no access to the
  artifact under review** — declared in `inputs:` and checked structurally.

Both forms are admissible. §5's property survives intact under (b): the validator
still reads where a stage sits and *what it can see*, never what it does, and the
admissibility of (b) is as un-gameable by prompt wording as (a) — a stage cannot
talk its way into having different inputs.

**What (b) requires, structurally:**

- The stage declares its `inputs:`, and none of them is the artifact under
  review. For a build-loop gate that means: not the diff, not the build summary,
  not the implementation under any name.
- The declaration is checked at load, in the same walk that enforces §5 today —
  not asserted in prose and not inferred from the prompt. The test is
  **cycle-relative**: an output produced by a member of the same cycle IS the
  artifact under review, because the cycle is what re-runs to change it. Inputs
  from outside the cycle are fixed for its duration and authored upstream, so
  the judged party cannot influence them.
- `GATE_SEES_REVIEWED` — a model-judged gate consuming a same-cycle member's
  output, named with the offending input.
- `GATE_ISOLATION_UNPROVEN` — a model-judged gate declaring no inputs. Absence
  of a declaration is not proof of isolation, so it fails closed.
- "Model-judged" is itself a DECLARED property: the manifest says it requires
  the router. It is not inferred from `kind:` — `spec-acceptance` is
  `kind: agent` and wholly mechanical, which is why §5 keys on the convergence
  marker rather than the kind in the first place.

**Explicitly rejected: a blanket "LLM stages may gate."** It would reopen exactly
what §5 closed, and the next author who wants a review lens to block would cite
it. The clause is narrow by construction: the isolation is the whole of it.

**On promotion.** Whether any *particular* (b)-form stage should gate is an
operational decision about that stage, separate from this one. The recommended
safeguard is the second-measurement pattern ADR-036 already uses for
`inert_wiring` (#1711): advisory on iteration 1, authoritative on iteration 2+,
which bounds a wrong verdict to one wasted iteration. Measuring a stage's
false-positive rate before promoting it is sound practice and belongs in that
stage's issue — it is not a condition of this clause. The architecture decides
what is *admissible*; a stage's own evidence decides whether it is *ready*.
