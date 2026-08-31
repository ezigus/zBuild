# ADR-061 — Fault-class vocabulary (stages stop naming stages)

**Status:** Accepted (2026-08-31)
**Issue:** #1987
**Supersedes:** the `route_target` scalar (ADR-045 §"route verdict"), and #1767
**Related:** ADR-054 §6 (verdict/disposition split — the precedent this mirrors),
ADR-055 (a consumer names the artifact, never the producer), ADR-045 (bounded
typed backward route), ADR-040 §5 (convergence-path invariant)

## Context

A gate that found a problem it could not fix wrote `route_target: design` into
its result. Two things are wrong with that, and they are the same two things
ADR-054 §6 separated for `disposition`.

**The stage picked the destination.** ADR-055 removed exactly this shape from
the data plane: a consumer declares the artifact *name* it needs and never the
producer, because naming a producer couples a plugin to a flow it cannot see.
`route_target` reintroduced it on the control plane. A gate that names `design`
is also simply wrong in any flow without a design stage — it names a
destination that does not exist, and #1767 records the consequence: *"a target
with no matching route_back edge is indistinguishable from no routing at all."*

**The vocabulary was undeclared.** With no closed set, the gate-aggregator
resolved two gates naming different targets by taking "the FIRST non-empty" over
roster order — file iteration deciding a routing question, with the loser
dropped silently until #1757 added an event.

## Decision

A gate declares the **kind** of fault it hit. The **template** maps that class
to a destination. The engine matches; it does not judge.

The word rides the standard result file, beside `verdict` and `reason`. No new
channel.

### The closed set

| Fault | Meaning |
|---|---|
| `specification` | What we agreed to build is wrong or unsatisfiable as written |
| `scope` | The boundary is wrong — the work needs files outside it |
| `implementation` | The code is wrong; fix it here, no rewind |

Each word exists because a template would route it differently. `scope` stays
distinct from `specification` even though both route to `design_verify_cycle` in
`simple.yaml` today: where intake or plan owns the boundary it routes elsewhere,
and merging them now would make every historical `specification` ambiguous if
they are split later.

`implementation` is an **explicit** word rather than an absent field, so "I
decided this is local" and "I never thought about it" stay distinguishable —
that ambiguity is what #1767 is about.

### What is deliberately absent

**`environment`.** `disposition` already answers "was this the work's fault?"
with `interrupted` / `throttled` / `unavailable` / `broken`, and the infra
failure classes already map to `disposition: advisory`. Two vocabularies
answering one question is how #1767 happened; the axes are orthogonal and must
stay so. `disposition` asks whether the stage got far enough to be believed;
`fault` asks, given a failure, whose problem it is.

**`input`.** The resolver refuses a missing or damaged input *before* dispatch,
so it never reaches a gate as a fault.

### Precedence

Selection across disagreeing gates is the **vocabulary's table order** — a
declared property of the engine, replacing file-iteration order. A word outside
the set is never selected and is announced (`gate_aggregator.fault_unrecognised`)
rather than dropped: a gate and the engine disagreeing about the contract is
itself the finding.

### The `in` operator

Predicates supported only `eq` and `ne`. Two routable classes sharing one
destination is inexpressible with equality, and expressing it as two edges needs
a list grammar the parser does not have. `in` matches any member of a
space-separated set. `eq`/`ne` are unchanged, so every existing predicate
behaves identically. It is available to `exit_when` and `abort_when` for the
same reason it is available here — a one-of condition is not special to routing.

## Consequences

- The aggregate verdict no longer mutates into `route_<target>`; it stays
  pass/fail. `exit_when` still binds to `verdict == pass`, and `route_back` keys
  on the fault. `route_design` is retired from `valid_verdicts`.
- ADR-040 §5 is untouched. It governs whether a stage may **block**; a fault
  class places no stage on a convergence path.
- The fault travels the same path `disposition` already does — read from the
  result file, carried on the dispatch, available to the cycle's predicates.

## Alternatives considered

**A triage stage that decides routing.** Rejected: it sits on the convergence
path, so an LLM implementation would violate ADR-040 §5's machine-enforced
invariant, and a mechanical one is the engine's mapping table with extra moving
parts — its own roster, its own verdict.

**Keep `route_target` and declare its vocabulary.** Rejected: it fixes the
undeclared half of #1767 and leaves the stage naming a stage, which is the half
ADR-055 already ruled on for data.

## Implementation Notes (issue #1987)

- `core/pipeline/fault.sh` mirrors `core/pipeline/disposition.sh`:
  `fault_vocabulary()`, `fault_is_valid()`, `fault_routes()`. `fault_routes`
  returns rc 2 for a non-member — "I cannot answer" is not "it does not rewind",
  the same discipline `disposition_halts` uses.
- The word travels the path `disposition` already travels:
  `runner_read_stage_fault` (`core/pipeline/verdict.sh`) reads it from the
  result file, `runner.sh` captures it on the dispatch, and
  `cycle-orchestrator.sh` carries it in the per-stage predicate blob. The
  routing predicate reads that blob, not the artifact — which is why the field
  had to be plumbed rather than merely written.
- `gate-aggregator` selects across disagreeing gates by iterating
  `fault_vocabulary()`, so precedence is the declared table order.
- The `in` operator is added to all four predicate sites and both load-time
  validators. `exit_when` and `abort_when` gain it too: a one-of condition is
  not special to routing, and leaving them on `eq`/`ne` would have been an
  arbitrary asymmetry.
- No template parser change was needed — the `when:` predicate was already
  generic over field and value.
