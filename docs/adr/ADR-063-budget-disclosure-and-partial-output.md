# ADR-063 — Stages are told their limits, and say when they hit them

**Status:** Proposed (2026-09-02)
**Issue:** #2032
**Amends:** ADR-054 §6 (no new vocabulary — `exhausted` is adopted, not invented)
**Related:** ADR-029 (budget escalation), ADR-060 (structure to the engine, prose to humans), #1986 (summary ingestion)

## Context

Every LLM stage runs under two limits — a tool-call turn budget and a wall-clock
timeout — and both are defined **outside** the model session. Most prompts never
mention them. The model works as though it has forever, gets cut off mid-thought,
and the attempt yields nothing.

Run [33548970231](https://github.com/ezigus/zBuild/actions/runs/33548970231) is
the worked example. Nine consecutive `design` calls, each killed at the 600s
ceiling, ten minutes apart, no variance:

```
⚠ route_to_model_loop: claude rc=124 iter=1
══ design [llm] seq=7.1.1 output FAIL 601.1s ══
```

Three hours. **The ninth attempt knew no more than the first.** Whatever caused
the individual timeouts — a rate limit, most likely — the part that is ours is
that nine attempts learned nothing from each other.

### The engine already knows what to do about this

`exhausted` is in ADR-054 §6's closed set, meaning "more budget, or the work must
shrink". It is wired end to end:

| | |
|---|---|
| `core/pipeline/disposition.sh:53` | in `_ZBUILD_DISPOSITION_SET` |
| `core/pipeline/disposition.sh:97` | `exhausted) printf 'escalate'` |
| `core/pipeline/dispatch-rc.sh:177` | `rc=10 → exhausted` |
| `core/router/route.sh:749` | `_route_escalate_timeout` — retry at +50%, capped at 2× base (ADR-029) |

**No LLM stage has ever emitted it.** The producer side was never built, so the
escalation path has never run. A stage that runs out of time simply dies, and the
engine sees a dead call rather than a stage saying "I ran out; here is what I
had".

This is the defect class this repo keeps finding: a declared mechanism with no
producer, indistinguishable from a working one until someone checks (#2024's kill
loop, #1976 "computed, written, and discarded", #1977 "the mechanism was inert").
**This ADR adds no vocabulary.** It connects producers to a response table that
already exists.

### Three stages already solve this, two different ways

The pattern is proven here; it is simply not applied consistently.

**By instruction — `plan`** (`plugin.sh:79-92`): states the turn budget, computes
a stop target at 70% of wall-clock, and says what to do on the way out — *"A
partial plan with gaps in `notes` BEATS a hard SIGTERM."*

**By instruction — `impact`** (`plugin.sh:218-226`): *"BUDGET DISCIPLINE (read
this — you have a BOUNDED tool-call budget) … STOP exploring and EMIT your JSON
verdict well before your budget runs out. If unsure but out of budget, return
verdict="incomplete" with the gaps."*

**By structure — `build`** (`lib/prompt.sh:13`): tells the model `iter N/M`, and
each iteration **commits**, with the diff fed into the next. A kill costs one
iteration, not the stage. The stronger form: it does not depend on the model
choosing to wind up in time.

Neither instructional stage signals partiality where a machine can see it. `plan`
puts gaps in a prose field; `impact` uses `verdict:"incomplete"`, its own
vocabulary, not the engine's axis. So today **no stage can be asked "was that
answer complete?" without reading prose.**

`design`, `monitor`, `review-lens`, `security-lens` and `review-report` do none of
it. `design` looks closest but is not: it carries a *prior design* forward
(`plugin.sh:338`, "refine, do not recreate") — which helps only once an attempt
has **succeeded at least once**. In run 33548970231 none did, so the carry-forward
never engaged.

## Decision

### 1. The budget reaches the prompt from the value that enforces it

One helper renders the budget block — turns, wall-clock seconds, and the stop
target — interpolated from the same numbers the engine will act on. Stages do not
restate them.

A hand-copied bound is worse than no bound: it drifts from what actually kills the
call, and then the prompt is lying to the model with authority. `plan` computes
its own stop target today and `impact` writes the budget as prose; both are
correct now and neither is pinned to the enforcing value.

### 2. Every LLM stage declares a partial form of its deliverable

A stage that cannot express "here is how far I got" has nothing to emit when it
runs out, and the instruction in §1 is unactionable. The partial form is declared
in the stage's schema, alongside the complete one.

The existing shapes are the model: `impact` has `verdict:incomplete` +
`missing[]`; `plan` has steps-so-far plus named gaps. `design` has none, which is
why it can only ever return everything or nothing.

### 3. Partial is signalled as `disposition: exhausted`

Machine-readable, on the engine's axis, using the word that already exists.

The stage's `verdict` stays its own vocabulary (ADR-054 §6) — `incomplete`,
`request_changes`, whatever the stage means. Disposition answers the different
question: *did this stage get far enough for that verdict to be worth reading?*

**Prose is not a signal.** This is ADR-060's rule applied to a different field: a
gap described in a `notes` string is for a human, and no engine path can branch on
it. `plan.notes` stays exactly as it is (#2033) — it is where the partial answer
is *explained*; `disposition` is where it is *declared*.

### 4. The engine's response fires, and gates fail closed on partial

Two halves, and neither is optional:

- `exhausted → escalate` already routes to `_route_escalate_timeout` (+50%,
  capped at 2× base). Wire the producers so it runs. A signal nothing acts on is
  the inert-mechanism defect one layer up.
- **A gate must not accept a partial as complete.** This is the risk the change
  introduces: giving `design` permission to emit early is dangerous precisely
  when the design gate cannot tell the difference, and a half-built design that
  passes is worse than a design stage that failed loudly. Any gate reading a
  stage whose disposition is `exhausted` fails closed unless it declares
  otherwise.

### 5. Two implementation shapes, chosen by the work

Both are legitimate and this ADR mandates neither:

| Shape | Example | Use when |
|---|---|---|
| **Checkpointing** | `build` — per-iteration commits, `iter N/M` | work is incremental; partial state is durable without the model's cooperation |
| **Early wind-up** | `plan`, `impact` — told the bound, asked to emit before it | the deliverable is one artifact; there is nothing to checkpoint |

Checkpointing is stronger where it applies, because it does not depend on the
model judging its own remaining budget correctly. `design` produces one artifact,
so it wants the early-wind-up shape.

### 6. Carry-forward rides on the existing summary channel

#1986 has every stage publish a summary and every following stage ingest them. A
partial attempt's summary is how the next attempt learns what the last one got
through. **Do not build a second channel for this.**

## Consequences

- **`exhausted` stops being decorative.** Its response table entry and ADR-029's
  escalation have never executed for an LLM stage; after this they do.
- **"Was that answer complete?" becomes answerable by a machine**, for every
  stage, without parsing prose.
- **A stage can be told to stop early, so some answers get worse.** That is the
  trade: a slightly thinner design that arrives beats a complete one that is
  killed at 601s and discarded. It is only a good trade while §4's gate rule
  holds — without it, thinner answers silently pass as complete ones.
- **Prompts get longer** by the budget block. Measurable against the turn budget
  itself, and small next to the file lists these prompts already carry.
- **The instructional shape depends on the model's self-assessment**, which is
  imperfect. That is why §5 prefers checkpointing where the work allows it, and
  why the bound in §1 must be the real one — a model asked to wind up against a
  wrong number winds up at the wrong time.

## Implementation Notes

Adoption order, cheapest evidence first:

1. **`design`** — the stage this ADR exists for, and the one whose failure is
   already documented. Early wind-up.
2. **the advisory lenses** (`review-lens`, `security-lens`, `review-report`) —
   cheapest to fix, least costly to get wrong, since they never gate.
3. **`monitor`**.
4. **`plan` and `impact`** — retrofit onto §1's shared block and add §3's
   disposition. Their instructions are already right; only the source of the
   numbers and the machine-readable signal change.
5. **`build`** — already checkpointed; confirm it reports `exhausted` when the
   iteration budget is spent rather than falling out silently.

The discriminating test, per stage: kill it at its bound and assert the next
attempt starts from something. A stage that passes that with the mechanism
removed is not testing it — the failure mode of every prior fix in this area.
