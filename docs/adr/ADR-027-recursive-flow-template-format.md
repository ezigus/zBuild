# ADR-027: Recursive Flow Template Format

**Status:** Proposed
**Date:** 2026-06-05
**Depends on:** ADR-013 (canonical stage list), ADR-016 (per-repository template resolution), ADR-020 (inter-stage data contract), ADR-021 v2 (pipeline cycle semantics)
**Implemented by:** #703 (Wave 17-B template loader + validator), #704 (Wave 17-C migration of `config/templates/standard.yaml` + golden updates), #705 (Wave 17-D amendments to ADR-013 and ADR-016).

## Context

Five rounds of user-driven design iteration during Wave 16 (the cycle-of-cycles
work that started at #698 and rolled forward into the present wave window)
converged on a single observation about the template shape today: the pipeline
describes itself in two parallel languages and the reader has to translate
between them on every read.

Today's `config/templates/standard.yaml` (the canonical example, end-to-end at
`config/templates/standard.yaml:1-81`) splits the contract into:

1. A top-level `stages:` list that prescribes **execution order** and inlines
   per-stage attrs for non-cycle stages (`gate`, `roles`, `io`, `router`).
2. A top-level `stage_definitions:` map that hoists per-stage attrs for
   **cycle members** (the `build`, `test`, `test_assessment` triple at
   `config/templates/standard.yaml:57-80`) — because those stages also need
   attrs but live inside a cycle's `stages: [...]` member list rather than at
   the top level.
3. Cycles declared **inline** inside `stages:` with their own nested
   `stages: [...]` member list (`config/templates/standard.yaml:34-46`), an
   `until:` predicate, `max_iterations:`, `on_max:`, and `feedback:` — a
   different shape from a leaf stage even though both are siblings under
   `stages:`.

Three friction patterns followed from that shape:

- **Mixed paradigm.** A reader scanning the template has to track which stages
  are defined inline (cycle siblings at the top level) versus which are
  hoisted (cycle members). Authors writing new templates hit the same fork:
  the rule "put attrs inline UNLESS the stage is a cycle member, in which
  case hoist to `stage_definitions:`" has no obvious motivating principle and
  no failure mode that catches violations early.
- **Cycles look unlike stages.** Today a cycle stage and a leaf stage are
  siblings under `stages:` but have completely different keys. The reader
  cannot tell at a glance whether a section is a cycle or a leaf without
  reading the keys. The runner internally treats cycles as stages (the cycle
  orchestrator dispatches its member list the same way the top-level runner
  dispatches the outer list) — but the template shape hides that symmetry.
- **Recursion is blocked by the schema.** A cycle inside a cycle today
  requires inventing a new keyword or repurposing `stage_definitions:`,
  because the inner cycle's member-attrs have nowhere natural to live. Wave
  16's three-level dogfood (build/test inside review-remediation inside the
  outer pipeline) exposed this directly: the existing shape does not extend
  to depth without convention sprawl.

The design iteration in Wave 16 surfaced the insight that resolves all three:
**cycles ARE stages**. A cycle is a stage that happens to contain its own
mini-flow. The runner walks any flow the same way at any depth. If the
template format encodes that recursive symmetry directly, the mixed paradigm
disappears.

## Decision

ADR-027 codifies a **recursive flow** template format. Five-bullet contract:

1. **Top-level metadata reserved set.** The reserved top-level keys are
   `{id, name, extends, defaults, flow, _comment}`. Every other top-level
   YAML key is a stage section keyed by stage ID.

2. **`flow:` is the ordered stage list.** `flow:` is an ordered list of stage
   IDs that prescribes execution order. It exists at the top level AND inside
   each cycle stage's section. The runner walks any `flow:` the same way at
   any depth — recursive symmetry. There is no parallel `stages:` /
   `stage_definitions:` split.

3. **Stage sections.** Every stage gets its own top-level YAML section keyed
   by its ID. Leaf stages declare `gate`, `roles`, `io`, `router`, and any
   other per-stage attrs. Cycle stages declare `type: cycle` plus their own
   `flow:` (members), `exit_when:`, `abort_when:` (optional),
   `max_iterations:`, `on_max:`, and `feedback:`. A stage's section is the
   single source of truth for its definition.

4. **Break-out contract.** `exit_when` is a predicate that ends THIS cycle
   when it fires; control returns to the next sibling in the OUTER scope's
   `flow:`. `abort_when` (optional) is a predicate that propagates outward
   and terminates the pipeline. `max_iterations` is the safety cap that
   prevents unbounded loops; `on_max: continue | abort_pipeline` decides
   which exit class fires when the cap is hit — `continue` behaves as if
   `exit_when` fired (next sibling), `abort_pipeline` behaves as if
   `abort_when` fired (terminate). Exactly one of these three paths
   (`exit_when` hits, `abort_when` hits, `max_iterations` cap with `on_max`)
   terminates every cycle.

5. **Verbose structured notation.** Predicates and feedback edges use
   structured fields throughout, matching today's standard.yaml convention.
   `exit_when` / `abort_when` use `{ stage, field, op, value }` (the `op`
   field carries `eq | neq | gt | gte | lt | lte | contains | matches`,
   preserving op-flexibility for future predicates). `feedback` entries use
   `from: { stage, output }` and `to: { stage, input, required }`.
   Consistency over compactness; the reader does not have to parse a
   shorthand to know what a predicate means.

## Boundary

What stays the same:

- **Per-stage manifests.** Each stage's `manifest.yaml` (plugin contract,
  ADR-020 inputs/outputs schema, gate semantics) is unchanged.
- **Plugin contract (ADR-020).** Stages still declare inputs/outputs via
  manifests; `feedback:` edges still flow data through the inter-stage data
  contract; cycle-feedback `source: cycle_feedback` inputs continue to work
  identically.
- **Runner dispatch loop semantics.** The runner still walks a flow in order,
  invokes each stage's gate, dispatches the plugin, captures stage-io
  (ADR-015). The "walk" is now uniform at every depth, but the per-stage
  behavior is unchanged.
- **Cycle execution model (ADR-021 v2).** The cycle orchestrator's iteration
  body, plateau detection, divergence detection, and termination paths are
  the same. ADR-027 reshapes how the cycle is *declared*, not how it *runs*.

What changes:

- **Template loader** (`scripts/lib/template-loader.sh`, Wave 17-B). The
  parser must distinguish reserved metadata keys from stage sections,
  discriminate stage type via the `type:` field, and recursively parse
  nested `flow:` inside cycle sections. See "Loader contract" below.
- **Contract validator.** The validator must enforce: every ID in any
  `flow:` resolves to a top-level stage section after `extends` merge; no
  cycle membership forms a reference cycle; `on_max` is one of
  `{continue, abort_pipeline}`; predicate `op` is in the supported set.
- **Golden tests** (`tests/golden/`). Every golden referencing
  `config/templates/standard.yaml` shape needs rewriting in Wave 17-C.
- **ADR-016 per-repo override semantics.** Per-repository overrides today
  patch into `stages:` or `stage_definitions:` by key. Under ADR-027, an
  override patches into a top-level stage section by ID. ADR-016 gets an
  amendment in Wave 17-D (#705).
- **ADR-013 canonical stage taxonomy.** The taxonomy is unchanged in content
  but gains a clarifying note that cycle stages are stages too (not a
  separate construct). Amended in Wave 17-D (#705).

## Loader contract

The template loader applies the following parsing rules in order. The rules
are written so that the same code path walks any `flow:` at any depth.

1. **Reserved metadata extraction.** Keys in
   `{id, name, extends, defaults, flow, _comment}` are extracted as template
   metadata. The top-level `flow:` becomes the outer execution order.
2. **Stage section enumeration.** Every remaining top-level key is a stage
   section. The key is the stage ID; the value is the stage's definition map.
3. **`extends` merge.** If the template `extends:` another template, the
   loader resolves the parent, applies the same enumeration, then merges
   per-stage sections by ID (child wins on conflict). After merge, every
   stage ID referenced by any `flow:` MUST resolve to a top-level section.
4. **Stage type discrimination.** Within each stage section, the `type:`
   field discriminates the stage class. Default is `leaf` if absent.
   `type: cycle` triggers recursive parsing of the section's own `flow:`.
5. **Cycle recursion.** A cycle section's `flow:` is a list of stage IDs
   that MUST also resolve to top-level stage sections (cycle members are
   not nested inside the cycle section — they live at the top level
   alongside everything else, and the cycle's `flow:` references them by
   ID). This is what makes the symmetry work: members of a cycle are
   first-class top-level stages that happen to be referenced from inside a
   cycle's `flow:` rather than (or in addition to) the outer `flow:`.
6. **Cycle reference acyclicity.** Cycle membership cannot form a reference
   cycle: a cycle stage `A` cannot transitively include itself in any
   descendant `flow:`. The validator catches this at load time.

## Example template

The standard pipeline at `config/templates/standard.yaml` in the ADR-027
format:

```yaml
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout

flow:
  - intake
  - plan
  - build_test_cycle
  - review

intake:
  gate: auto
  roles: [intake]
  io:
    destinations: [file, stdout]
    tail_lines: 200

plan:
  gate: auto
  roles: [planner]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25

build_test_cycle:
  type: cycle
  flow:
    - build
    - test
    - test_assessment
  exit_when:
    stage: test_assessment
    field: verdict
    op: eq
    value: pass
  max_iterations: 3
  on_max: continue
  feedback:
    - from:
        stage: test_assessment
        output: test_assessment_md
      to:
        stage: build
        input: prior_test_assessment
        required: false

build:
  gate: auto
  roles: [builder]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 900

test:
  gate: auto
  roles: [tester]
  io:
    destinations: [file, stdout]
    tail_lines: 200

test_assessment:
  gate: auto
  roles: [test_assessment]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25

review:
  gate: auto
  roles: [reviewer]
  io:
    destinations: [file, stdout]
    tail_lines: 200
  router:
    timeout_s: 300
    max_turns: 25
```

Notes on the example:

- The top-level `flow:` lists four IDs. Three are leaf stages (`intake`,
  `plan`, `review`); one is a cycle (`build_test_cycle`).
- `build_test_cycle.flow` references three stage IDs (`build`, `test`,
  `test_assessment`) that are defined as top-level sections — identical in
  shape to the leaf stages, discoverable by the same enumeration pass.
- The `until:` predicate from ADR-021 v2 is renamed `exit_when:` to make the
  break-out contract explicit (it ends THIS cycle, returns to outer
  sibling). The op-flexibility (`eq`, `neq`, `gt`, etc.) is preserved.
- No `stages:` key, no `stage_definitions:` key. One language.

## Alternatives considered

- **(a) `remediation_loop:` keyword on the review stage.** Add a per-stage
  `remediation_loop:` block that names a feedback edge back to an earlier
  stage. Rejected: adds vocabulary that only solves one shape (single-stage
  retry), does not generalize to multi-stage cycles, and mixes flow control
  with stage attrs at the same scope. Would have to be re-invented for
  build/test/test_assessment, which is the same shape today's cycle solves.

- **(b) Keep `stages:` + `stage_definitions:` and nest cycles.** Extend the
  existing format by allowing a cycle stage's inline `stages: [...]`
  member list to itself contain cycles. Rejected: preserves the mixed
  paradigm (the reader still must track inline-vs-hoisted), and depth-2
  nesting forces a third convention for where the depth-2 member attrs
  live. The readability problem is the format, not the depth.

- **(c) Per-stage YAML files (one file per stage).** Move each stage's
  section to a separate file under `config/templates/<template>/<stage>.yaml`.
  Rejected for now: complicates the loader (multi-file resolution + glob
  order), complicates ADR-016 per-repo override semantics (overrides
  would need to know which file to patch), and adds filesystem ceremony
  for what is today a small enough single file. Forward-looking option;
  becomes attractive if standard.yaml grows past ~500 lines or if many
  templates share many stages.

- **(d) Dotted-shorthand notation** (`from: review.review_md`,
  `exit_when: test_assessment.verdict == pass`). Rejected for now: less
  consistent with today's standard.yaml verbose convention, loses
  op-flexibility for predicates (a string DSL forces a parser), and
  requires authors to learn a second mini-language inside YAML. Revisit
  if the verbose shape proves limiting in practice (e.g., template files
  routinely exceed a comfortable reading length because of structural
  verbosity).

## Consequences

**Easier:**

- Recursive symmetry. The runner walks a flow the same way at any depth.
  Cycles can nest indefinitely without inventing new keywords.
- Each stage section is self-contained. To understand a stage, a reader
  looks at one section. No cross-referencing between `stages:` and
  `stage_definitions:`.
- Adding a new stage means writing one section and adding its ID to a
  `flow:`. No fork between "is this a cycle member or a sibling?".
- Cycles look like stages (because they ARE stages). A reader scanning the
  template sees uniform sections; the `type:` field discriminates.

**Harder:**

- Template loader requires recursion handling — `extends` merge, reserved
  key extraction, top-level enumeration, cycle-section recursion. Wave
  17-B owns this work.
- ADR-016 per-repo override semantics need amendment to patch into stage
  sections by ID rather than into `stages:` / `stage_definitions:` by key.
  Wave 17-D owns the ADR-016 amendment.
- Golden tests need rewriting. Wave 17-C migrates
  `config/templates/standard.yaml` + every golden that snapshots the
  pre-ADR-027 shape.

**Migration story:**

- Wave 17-B ships the new loader behind a back-compat shim that accepts the
  pre-ADR-027 shape (`stages:` + `stage_definitions:` + inline cycles) and
  emits a `template.format.deprecated` event with the file path. The shim
  rewrites the old shape into the new shape internally so the runner only
  sees one format downstream.
- Wave 17-C migrates `config/templates/standard.yaml` to the new shape and
  updates all goldens.
- The shim lives for one release window (one tagged release) and is removed
  in the release after Wave 17-C lands. The deprecation event surfaces in
  the events bus so any per-repo template that still uses the old shape
  surfaces in operator dashboards before the shim removal.

## Status flip

ADR-027 ships in **Proposed** status. The status flips from Proposed to
**Accepted** when Wave 17-B (#703) merges the template loader + validator.
This matches the ADR-then-impl pattern used by ADR-015 (flipped on #438),
ADR-016 (per-repo template resolution), and ADR-024 (flipped on #673 in
Wave 13-B). No code, no test, no event-schema changes in this PR. Only the
ADR text.

## Implementation Notes (Proposed — 2026-06-05)

This ADR ships in **Proposed** status. No code, no test, no event-schema
changes in this PR. The status flips to **Accepted** when Wave 17-B
(#703) lands the template loader + validator + back-compat shim.

The impl sequence:

- **Wave 17-B (#703)** — template loader in `scripts/lib/template-loader.sh`
  that implements the six "Loader contract" rules above; contract validator
  that enforces reserved-key set, `flow:` ID resolution, cycle membership
  acyclicity, `on_max` enum, and predicate `op` enum; back-compat shim that
  rewrites the pre-ADR-027 shape into the new shape internally and emits
  `template.format.deprecated` events. ADR-027 flips Proposed → Accepted on
  this merge.
- **Wave 17-C (#704)** — migrate `config/templates/standard.yaml` to the
  ADR-027 shape (the example in section 5 above becomes the new file
  verbatim); rewrite every golden under `tests/golden/` that snapshots the
  pre-ADR-027 shape.
- **Wave 17-D (#705)** — amend ADR-013 with a clarifying note that cycle
  stages are stages (no taxonomy content change); amend ADR-016 so per-repo
  overrides patch into stage sections by ID under the new shape.
- **Back-compat shim lifecycle** — the shim ships in Wave 17-B and lives
  for one tagged-release window. It is removed in the release after Wave
  17-C lands. The `template.format.deprecated` event surfaces in operator
  dashboards so any per-repo template using the old shape is visible
  before the shim removal.
- **Wave 18 builds on this** — #706 (ADR-026), #707 (`review_cycle`),
  #708 (contract lint enforcing ADR-027 invariants) all assume the
  recursive `flow:` shape is in place.

This PR (closing #702) lands only the ADR text.

## References

- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage taxonomy;
  amended in Wave 17-D (#705) with a clarifying note that cycle stages are
  stages (no taxonomy change in content).
- [ADR-016](ADR-016-per-repository-template-resolution.md) — per-repository
  template resolution; amended in Wave 17-D (#705) to patch overrides into
  stage sections by ID under the ADR-027 shape.
- [ADR-020](ADR-020-inter-stage-data-contract.md) — inter-stage data
  contract; unchanged. `feedback:` edges still flow through ADR-020.
- [ADR-021 v2](ADR-021-pipeline-cycle-semantics.md) — cycle semantics;
  extended (not replaced) by ADR-027. Cycle execution model is identical;
  only the declaration shape changes. The `until:` predicate is renamed
  `exit_when:` to make the break-out contract explicit.
- [ADR-022](ADR-022-test-assessment-stage.md) — test_assessment stage;
  unchanged.
- [ADR-024](ADR-024-subprocess-env-isolation.md) — recent ADR-then-impl
  precedent; structure modeled on its Proposed-to-Accepted flip pattern.
- [ADR-015](ADR-015-stage-io-capture.md) — stage-io capture; the original
  Proposed-then-Accepted precedent, cited from ADR-016 and ADR-024.
- Wave 16 design discussion — five rounds of iteration on the recursive
  `flow:` shape that this ADR codifies.
- Issue #702 (this ADR; Wave 17-A).
- Issue #703 (Wave 17-B) — template loader + validator + back-compat shim;
  flips ADR-027 to Accepted.
- Issue #704 (Wave 17-C) — migrate `config/templates/standard.yaml` +
  golden updates.
- Issue #705 (Wave 17-D) — amend ADR-013 (cycle-stages-are-stages note)
  and ADR-016 (override semantics under ADR-027).
- Issue #706 (Wave 18-A) — ADR-026 builds on the recursive-flow shape.
- Issue #707 (Wave 18-B) — `review_cycle` uses ADR-027 to declare a
  multi-stage review remediation loop.
- Issue #708 (Wave 18-C) — contract lint enforces ADR-027 invariants
  (reserved key set, flow ID resolution, cycle acyclicity).
