# ADR-039 — Parallel stage groups (`type: parallel` flow construct)

**Status:** Accepted (2026-06-27)
**Related** — dispositions below are **PLANNED** (declared here, executed in later issues of EPIC #1129 alongside the code that lands the construct); **this PR edits no existing ADR**:
- amend-planned: ADR-027 (recursive-flow grammar gains a `type: parallel` sibling of `type: cycle`)
- amend-planned: ADR-021 (cycle/convergence semantics gain a group-verdict aggregation path)
- amend-planned: ADR-013 (canonical-stage list — parallel-group member ids are a canonical-id exemption, addressed by stage id not by a new pipeline row)
- amend-planned: ADR-015 (stage-io capture under concurrent member dispatch — per-member sequence, flock-append `events.jsonl`)
- peer: ADR-040 (composable gate/lens taxonomy) — the first heavy consumer of parallel groups; EPIC #1129
**Issue:** #1143 (EPIC #1129, D1)
**Amended by:** ADR-042 — parallel-group members now resolve their plugin role-then-id via the shared `resolve_stage_plugin` helper, not id-only.

## Context

ADR-027 gave the template one recursive language: a `flow:` is an ordered list of stage ids, and a
stage section discriminates its class via `type:` (`leaf` by default, `type: cycle` for a mini-flow).
The runner walks any `flow:` the same way at any depth. Every construct so far is **sequential** — the
runner dispatches one member, waits, then dispatches the next.

Two forces now push against the sequential-only shape:

- **ADR-037/ADR-038 decompose the quality machinery into many independent stages.** The objective gate
  layer is no longer one monolith; it is a *set* of mechanical gates (suite-green, lint, `negctl`,
  reachability, shape-floor, coverage-floor, scope-adherence). The semantic layer (ADR-038) is a *set*
  of evidence-fed lenses. Members within each set are independent — a lint gate does not consume the
  `negctl` gate's output, and the security lens does not consume the performance lens's. Run serially,
  the gate set and the lens fan-out add their latencies; the pipeline's wall-clock grows linearly with
  the number of gates and lenses precisely as the design adds more of them.

- **The fan-out pattern already exists, hand-rolled and unrepeatable.** ADR-038's review stage runs its
  lenses with a bespoke bounded-parallel subshell loop inside one plugin (the #972/#974 fan-out, noted
  in MEMORY: "bounded-parallel lens fan-out (N subshells, `ZBUILD_CURRENT_STAGE` unset to dodge
  `route_to_model` global-state corruption, PID-tracked wait)"). That concurrency lives *below* the
  template, invisible to the flow grammar, with its own ad-hoc isolation workarounds. The gate layer
  wants the same thing and would re-invent it. Concurrency belongs in the flow language, declared once,
  not re-implemented per plugin.

There is already a **proven, in-tree bounded-parallel primitive**: `scripts/run-mutation.sh:367-379`
runs each mutant in a detached subshell, capping concurrency with a FIFO pool that is **bash-3.2-safe
(no `wait -n`)** — it waits on the oldest PID and shifts the array. EPIC #982's worktree-per-mutant
parallelization is byte-identical to its serial form. That FIFO pool is the dispatch mechanism to reuse;
what's missing is a *template construct* that declares "these members run concurrently" and an
*aggregator* that collapses N member verdicts into one group verdict the surrounding `flow:` can branch
on.

## Decision

Add a third stage class to the ADR-027 recursive-flow grammar: **`type: parallel`** — a stage group
whose members run as bounded concurrent dispatch instead of in sequence. It is a grammar sibling of
`type: cycle`: same recursive symmetry (members are first-class top-level stage sections referenced by
id from the group's `flow:`), different dispatch policy (concurrent, bounded) and a different
termination shape (aggregate, not iterate).

### 1. Grammar — a sibling of `type: cycle`

A parallel group is a stage section with `type: parallel` plus its own `flow:` of member stage ids:

```yaml
flow:
  - intake
  - plan
  - objective_gates      # a parallel group
  - review

objective_gates:
  type: parallel
  flow:                  # members run concurrently, not in order
    - gate_suite
    - gate_lint
    - gate_negctl
    - gate_coverage
  max_parallel: 4        # FIFO-pool cap (optional; default below)
  aggregate: all_pass    # how member verdicts collapse to a group verdict
  exit_when:             # evaluated against the AGGREGATED group verdict
    stage: objective_gates
    field: verdict
    op: eq
    value: pass
```

The members (`gate_suite`, `gate_lint`, …) are ordinary top-level stage sections — identical in shape to
leaf stages, discoverable by the same enumeration pass (ADR-027 rule 2/5). The **only** semantic of
`type: parallel` is "dispatch this `flow:`'s members concurrently and aggregate, rather than in order."
The member `flow:` list order is **not** an execution order — it is the membership set (and the stable
order used for deterministic aggregation/reporting).

### 2. Bounded concurrent dispatch — reuse the FIFO pool

Members are dispatched through the **same bash-3.2-safe FIFO pool** proven at
`scripts/run-mutation.sh:367-379`: launch each member in a backgrounded subshell, track its PID, and
once the in-flight count reaches the cap `wait` on the **oldest** PID and shift the array (no `wait -n`,
which bash 3.2 lacks). After the dispatch loop, drain the remaining PIDs. The cap is `max_parallel`
(template field), defaulting to the engine's standard job-count default (`_zb_default_jobs`, the same
default `run-tests.sh` and `run-mutation.sh` use — typically `min(nproc, sensible-cap)`), overridable by
`ZBUILD_PARALLEL_JOBS`. `max_parallel: 1` degrades a parallel group to sequential dispatch — a useful
escape hatch for debugging or constrained CI.

The pool is the **only** new concurrency in the engine; the per-plugin hand-rolled fan-out (ADR-038
#972/#974) is rehomed onto it in a later issue so there is one concurrency primitive, not two.

### 3. Per-member subshell isolation (the correctness core)

Each member runs in its own subshell. The isolation contract — learned from both `run-mutation.sh` and
ADR-038's fan-out workaround — is:

- **stage-io is per-member and sequenced** (ADR-015). Each member writes its own stage-io artifacts
  under its own stage id; the renderer is invoked per member. Concurrent members never share a stage-io
  buffer or a tail window.
- **`ZBUILD_CURRENT_STAGE` is set per member inside its subshell**, never inherited across members. This
  is the explicit cure for the `route_to_model` global-state corruption that forced ADR-038's fan-out to
  *unset* the variable defensively: with `type: parallel`, each subshell sets its own member stage id, so
  router/redaction stage-scoping is correct per member instead of being blanked. The router's **C6
  precondition is scoped to this per-member stage** (ADR-004 amendment): `eb_emit_event` stamps a top-level
  `stage` field on every in-stage event, and `_route_check_precondition` validates that the most-recent
  event for `(run_id, ZBUILD_CURRENT_STAGE)` — not the run-global most-recent — is `redaction.applied`.
  Without this, a sibling member's interleaved `plugin.run.start` becomes the run-global most-recent event
  and fails C6 for every concurrent LLM member (observed in the first `review_lenses` dogfood run,
  `20260629214235-33569`). Each member now provably enforces its own redaction independently.
  **Amended by [ADR-043](ADR-043-redaction-by-construction.md):** the per-`(run_id, stage)`
  most-recent-`redaction.applied` check is no longer a *refusal gate* (`_route_check_precondition`
  is retired) — it is now a per-stage **dedup** in `_route_ensure_redaction`. A member that already
  redacted proceeds unchanged; a member that has not is redacted by the router by construction and
  emits its OWN `redaction.applied` stamped with its stage (it still never rides a sibling's
  redaction). The per-stage scoping remains essential — it is what makes the dedup member-correct.
- **`events.jsonl` is append-only via `flock`.** Concurrent members emit events; the append is
  serialized by an advisory lock so the event log stays a valid JSONL stream (no interleaved partial
  lines). Event ordering across members is by append time and is not asserted to follow member-`flow:`
  order.
- **State writes are parent-serial.** Member subshells do **not** write orchestrator run-state
  (`runs/<run_id>/…`, ADR-035). A member produces its artifacts + a per-slot result file (verdict +
  the renderable line), exactly as `run-mutation.sh` has each worktree subshell write a `.line`/`.status`
  slot; the **parent** reads those slots after the pool drains and performs all run-state mutation
  serially, in member-`flow:` order. This keeps the concurrent-run-corruption class (the #887 lineage)
  closed: no two subshells race the same state file because subshells touch no shared state file.

### 4. The aggregator — N member verdicts → one group verdict

After the pool drains, an **aggregator** collapses the N per-slot member verdicts into a single group
verdict that the surrounding `flow:` treats exactly like a leaf stage's verdict — so `exit_when` /
`abort_when` / `blocking` (ADR-027 §4) evaluate against `<group_id>.verdict` with no new predicate
grammar. Aggregation policy is the `aggregate:` template field:

- `all_pass` (**default**) — group verdict is `pass` iff **every** member passed; otherwise `fail`. This
  is the gate-set policy (ADR-040): one failing mechanical gate fails the group, which can block.
- `advisory` — the group **always** aggregates to a non-blocking report (member findings merged +
  de-duped); the group verdict is informational and never `fail`. This is the lens fan-out policy
  (ADR-040): no lens blocks merge.
- `quorum:<n>` / `any_pass` — reserved threshold policies for future consumers; named here so the field
  is forward-stable, specified when first used.

The aggregator runs **in the parent, serially, after the drain** — it is deterministic (reads the stable
member-`flow:` order), contains no concurrency, and (for `all_pass`) contains no LLM. Aggregation is
total: every member contributes exactly one verdict slot; a member that crashed or timed out contributes
a `fail` slot (for `all_pass`) or an "evidence unavailable" finding (for `advisory`), never a missing
slot — mirroring `run-mutation.sh`'s `(no result)` fallback so the aggregate is never silently short.

### 5. What stays the same (boundary)

- **ADR-027 recursion is unchanged.** A parallel group's members are top-level stage sections referenced
  by id; the loader's enumeration/`extends`-merge/acyclicity rules apply verbatim. A parallel group may
  contain a cycle member and a cycle may contain a parallel group — the recursive symmetry holds because
  `type:` discriminates dispatch policy, not flow shape.
- **ADR-020 inter-stage data contract is unchanged.** Members declare inputs/outputs via their manifests;
  `feedback:` edges still flow through ADR-020. Members of one group do **not** feed each other (that is
  what makes them parallelizable); cross-member data dependence is a modeling error the validator can
  flag (a `feedback:` edge between two siblings of the same parallel group).
- **The cycle execution model (ADR-021) is unchanged.** Parallel groups do not iterate; they aggregate
  once. Convergence (ADR-021) consumes the aggregated group verdict the same way it consumes a leaf
  verdict.

## Consequences

- The objective-gate set and the semantic-lens fan-out run in wall-clock close to their slowest member
  instead of the sum of all members — the decomposition ADR-037/ADR-038 mandate stops being a latency
  regression.
- Concurrency becomes a **declared, auditable** template property (`type: parallel`, `max_parallel`,
  `aggregate`) instead of plugin-internal subshell code. There is one concurrency primitive (the FIFO
  pool) and one isolation contract (§3), reused, not re-invented per stage.
- The `route_to_model` global-state hazard that forced ADR-038's fan-out to blank `ZBUILD_CURRENT_STAGE`
  is structurally fixed: per-member subshells set their own stage id.
- The aggregator gives `exit_when`/`blocking` a single group verdict, so a parallel group is a drop-in
  flow member — no new predicate grammar, no special-casing in the convergence layer.
- New risk surface: concurrent stage-io / event emission. The isolation contract (§3) is the mitigation;
  the parent-serial state-write rule keeps the #887 concurrent-state-corruption class closed by
  construction (subshells touch no shared state file).

## Implementation Notes (EPIC #1129, planned)

### Phase 1 — `aggregate:` wired through the runtime (issue #1177)

A parallel group's `aggregate:` declaration is now parsed by `core/pipeline/template.sh` — BOTH the awk
translator `_tpl_translate_new_shape` (it carries `aggregate:` as a 5th field on the `IP|` row) AND the
`IP|` loader arm (which exports `_TPL_PARALLEL_AGGREGATE_<id>`). Previously only the CI lint
(`scripts/lib/lint-contract.sh`) read it. The preflight binds an `aggregate: advisory` group to its
explicit `convergence: advisory` aggregator stage (e.g. `review-aggregator`); see ADR-040 §Phase 1. The
loader and lint parsers stay in sync (guarded by `tests/unit/core-pipeline-template-parallel-test.sh`
and the convergence lint/preflight tests).

The original ADR PR (issue #1143, D1) authored the ADR text only — no code/template/test changes beyond
the two new ADR files. The construct landed in later EPIC #1129 issues (the Phase 1 section above, issue
#1177, wired `aggregate:` through the runtime), in this order:

- **Grammar + loader/validator** — `scripts/lib/template-loader.sh` discriminates `type: parallel`
  (ADR-027 rule 4), parses `max_parallel` / `aggregate`, and the validator rejects a `feedback:` edge
  between two siblings of one parallel group (the cross-member-dependence modeling error) and enforces
  `aggregate` ∈ the named set. This executes the **planned ADR-027 amendment** declared in the header.
- **Dispatch + isolation** — the runner gains a parallel-group dispatcher reusing the
  `scripts/run-mutation.sh:367-379` FIFO pool (bash-3.2-safe), with the §3 per-member subshell isolation
  (per-member stage-io sequence, per-member `ZBUILD_CURRENT_STAGE`, flock-append `events.jsonl`,
  parent-serial state writes). This executes the **planned ADR-015 amendment** (concurrent stage-io).
- **Aggregator + convergence** — the parent-serial aggregator (`all_pass` / `advisory` first; `quorum` /
  `any_pass` reserved) emits `<group_id>.verdict`; ADR-021's convergence path consumes it like a leaf
  verdict. This executes the **planned ADR-021 amendment**.
- **Canonical-id exemption** — ADR-013 gains a note that parallel-group member ids are addressed by
  stage id (the same exemption posture cycle members already have), not new top-level pipeline rows.
  This executes the **planned ADR-013 amendment**.
- **First consumer** — ADR-040 repackages the objective-gate set and the semantic-lens fan-out as
  parallel groups (`aggregate: all_pass` for gates, `aggregate: advisory` for lenses), retiring
  ADR-038's hand-rolled per-plugin fan-out onto this one primitive.

Ordering guard: the loader/validator and the isolation contract MUST land before any template adopts
`type: parallel`, or a group dispatches with the old (unset-`ZBUILD_CURRENT_STAGE`) workaround and
re-opens the global-state hazard the construct exists to fix.

### Phase 2 — the advisory aggregator is ROSTER-DRIVEN (naming-agnostic)

`review-aggregator` no longer globs `lens-*.json` from the shared artifacts dir. It is now
**roster-driven**, exactly like `gate-aggregator` (ADR-040 §2): it discovers WHICH files to merge from
the parallel group's declared membership, not from a filename pattern.

Because the advisory aggregator runs as a **separate, non-member stage**, it **self-resolves** which
group it serves via the Phase 1 binding (above): it scans `_TPL_PARALLEL_GROUPS` for the
`aggregate: advisory` group whose bound aggregator — the *first non-member `convergence: advisory` stage*
in canonical (`_TPL_STAGES`) order, the same rule `core/pipeline/contract-validator.sh` /
`scripts/lib/lint-contract.sh` enforce — is THIS stage (`ZBUILD_CURRENT_STAGE`). With a single advisory
group this resolves to `simple.yaml`'s `review_lenses`. It then reads that group's members from
`_TPL_PARALLEL_FLOW_<group>` and, for each member, resolves the member's manifest (id-first, then
`provides.role`) and its **declared result artifact** (`provides.artifact_type`, else the basename of the
primary output's declared path) — mirroring `gate-aggregator`'s `_ga_member_manifest` /
`_ga_manifest_result_file`. A member output path that is per-member parameterized (review-lens's
`lens-${ZBUILD_REVIEW_LENS_ID}.json`) has its `${…}` placeholder expanded to the member's derived lens id
(the member stage id minus the `review-lens-`/`lens-`/`lens_` prefix), so the real `review_lenses` group
still resolves to each member's `lens-<id>.json`.

Consequence: adding/removing/renaming a lens member changes what the aggregator merges with **no edit to
the plugin**, and members are no longer required to be named `lens-*` — the aggregator follows the
roster, not the filename. A **legacy `lens-*.json` glob fallback** is retained for cycle-less / standalone
invocation (unit tests, or any context with no group binding in scope), mirroring `gate-aggregator`'s
fallback. The discovery mode (`roster` | `glob`) is recorded on the `plugin.run.complete` /
`review_aggregator.no_lenses` events. Guarded by `tests/unit/review-aggregator-roster-test.sh` (roster
discovery + self-resolution + fallback) alongside the existing `tests/unit/review-aggregator-test.sh`
(glob fallback) and `tests/integration/review-report-advisory-flow-test.sh`.

## References

- [ADR-027](ADR-027-recursive-flow-template-format.md) — recursive-flow template format; `type: parallel`
  is a grammar sibling of its `type: cycle`. **Amend-planned** (later EPIC #1129 issue).
- [ADR-021](ADR-021-pipeline-cycle-semantics.md) — pipeline cycle semantics; convergence consumes the
  aggregated group verdict like a leaf verdict. **Amend-planned**.
- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list; parallel-group member ids are a
  by-stage-id exemption. **Amend-planned**.
- [ADR-015](ADR-015-stage-io-capture.md) — stage-io capture; per-member sequence + flock-append under
  concurrent dispatch. **Amend-planned**.
- [ADR-040](ADR-040-composable-gate-lens-taxonomy.md) — composable gate/lens taxonomy; the first heavy
  consumer of parallel groups (gate set + lens fan-out). Peer in EPIC #1129.
- [ADR-035](ADR-035-orchestrator-run-state-isolation.md) — run-state isolation; the parent-serial
  state-write rule (§3) preserves it under concurrent members.
- `scripts/run-mutation.sh:367-379` — the bash-3.2-safe FIFO pool (no `wait -n`) reused as the bounded
  concurrent dispatch primitive (EPIC #982 worktree-per-mutant precedent).
- ADR-037/ADR-038 — the decomposition that motivates declared concurrency.
- Issue #1143 (EPIC #1129, D1) — this ADR text.

## Amendment (Issue OUT — terminal rendering contract for parallel groups)

The terminal rendering contract for a parallel group is now explicit and mirrors
the cycle rendering contract (§524):

- **Entry banner** (existing) — `_render_parallel_entry`, emitted by the runner
  before `parallel_group_run`.
- **Per-member one-line completion summary** — emitted by
  `parallel_member_complete_hook` (runner-registered) via
  `render_parallel_member_line`. Called by the orchestrator in the PARENT
  post-join aggregation loop, in member-DECLARATION order, parent-serial — so
  the lines never interleave (rendering inside the member subshells would
  interleave out of completion order). Members are file-only (ADR-015), so this
  one-liner REPLACES the streamed full I/O; the full lens JSON stays in the
  `lens-<id>.json` artifact.
- **Optional group-completion trailer** — `parallel_group_complete_hook` /
  `_render_parallel_group_complete`, mirroring `_render_cycle_exit`
  (`▸ <group> complete — N members, M blocking`).

As with the cycle hooks, `parallel-orchestrator.sh` stays render-free: it calls
the runner-registered hooks (guarded by `declare -F`) and never formats terminal
output itself. Guarded by `tests/integration/parallel-orchestrator-test.sh`
(hook invoked once per member in declaration order) and
`tests/integration/review-lenses-output-test.sh` (one human-readable line per
lens; no raw JSON on the terminal).
