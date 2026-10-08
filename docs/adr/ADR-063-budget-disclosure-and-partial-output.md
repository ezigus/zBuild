# ADR-063 — Stages are told their limits, and say when they hit them

**Status:** Accepted, amended 2026-10-05 by #2032
**Issue:** #2032
**Amends:** ADR-054 §6 (vocabulary updated to `timed_out`/`out_of_turns` per #2187)
**Amended:** 2026-10-05 (#2032) — vocabulary updated per #2187: the stale disposition word and the stale §4 engine action word are retired; `timed_out`/`out_of_turns` replace the former, and the engine's timeout-retry path (ADR-029) replaces the latter; §1 per-stage `_<stage>_budget_guidance` helpers replace the single shared helper.
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

`timed_out` and `out_of_turns` (the vocabulary #2187 standardised from the earlier
`exhausted`) are in ADR-054 §6's closed set, meaning "more budget, or the work must
shrink". The classification chain is wired end to end:

| | |
|---|---|
| `core/pipeline/disposition.sh` | `_ZBUILD_DISPOSITION_SET` includes `timed_out`, `out_of_turns` |
| `scripts/lib/router-rc-classify.sh:280` | `router_reason_disposition` — maps router reason to disposition word |
| `core/router/route.sh` | `_route_escalate_timeout` — retry at +50%, capped at 2× base (ADR-029) |

**No LLM stage emitted the signal.** The producer side was never built, so the
escalation path never ran. A stage that ran out of time simply died, and the
engine saw a dead call rather than a stage saying "I ran out; here is what I
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

### 0. Which parts depend on the contract-v2 migration

The four sections below do **not** share a dependency, and the difference decides
when each can land. This has been re-derived from the code twice; recording it so
it is not a third time.

| | | needs v2? |
|---|---|---|
| §1 | budget reaches the prompt from the value that enforces it | **no** — prompt text |
| §2 | each stage declares a partial form of its deliverable | **no** for a stage whose deliverable is a file |
| §3 | partial is signalled as `disposition: timed_out` or `out_of_turns` | **yes** |
| §4 | gates fail closed on unfinished dispositions | **yes** |

§3 and §4 are blocked because `disposition` is a v2-only field:
`runner_read_stage_disposition` (`core/pipeline/verdict.sh:674`) reads it from the
result file, and `_verdict_read_result` resolves `result_contract // 1`. ADR-054 §6
consults the vocabulary only at `result_contract >= 2`, and **none of the eight
model-driven stages is on v2** (tracked as [Phase 0/F], #1833–#1850). A stage
emitting an unfinished disposition before its migration writes a field nothing reads.

**§1 and §2 nonetheless wait for §3 and §4, by choice.** They are technically
unblocked, and the temptation to land them early is real — they are where the cost
is. But today a stage that runs out of time fails *loudly*: the run stops and
nothing ships. Letting a stage hand back partial work before §4 can refuse it
swaps that for a quiet failure — a half-finished deliverable that looks complete,
accepted, with everything downstream built on it. A loud failure is the better of
the two, so all four land together, per stage, during that stage's v2 migration.

The per-stage work is recorded on the migration issues themselves — #1834
(`design`), #1840/#1843 (`review-lens`, `review-report`), #1847 (`monitor`) — so
it is found at the moment those files are opened rather than depending on someone
remembering this ADR.

### 1. The budget reaches the prompt from the value that enforces it

Each stage has its own `_<stage>_budget_guidance` helper that reads the enforcing
values — turns, wall-clock seconds, and the stop target — and renders the budget
block for that stage's prompt. Stages do not restate them; the helper interpolates
from the same numbers the engine will act on (e.g. `_spec_coverage_budget_guidance`,
`_spec_correspondence_budget_guidance`, `_review_lens_budget_guidance`).

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

### 3. Partial is signalled with an unfinished disposition word

Machine-readable, on the engine's axis, using the vocabulary `router_reason_disposition`
(`scripts/lib/router-rc-classify.sh`) classifies from the router exit code:
`timed_out` (rc=124, wall-clock killed), `out_of_turns` (turn budget hit),
`interrupted` (signal), and related words. Stages call `router_reason_disposition`
instead of hardcoding `complete` — the word `complete` must never be hardcoded
for a model-calling stage when the model call may not have finished.

The stage's `verdict` stays its own vocabulary (ADR-054 §6) — `incomplete`,
`request_changes`, whatever the stage means. Disposition answers the different
question: *did this stage get far enough for that verdict to be worth reading?*

**Prose is not a signal.** This is ADR-060's rule applied to a different field: a
gap described in a `notes` string is for a human, and no engine path can branch on
it. `plan.notes` stays exactly as it is (#2033) — it is where the partial answer
is *explained*; `disposition` is where it is *declared*.

### 4. The engine's response fires, and gates fail closed on partial

Two halves, and neither is optional:

- An unfinished disposition (`timed_out`, `out_of_turns`) routes to
  `_route_escalate_timeout` (+50%, capped at 2× base, via ADR-029/route.sh).
  Wire the producers so it runs. A signal nothing acts on is the
  inert-mechanism defect one layer up.
- **A gate must not accept a partial as complete.** This is the risk the change
  introduces: giving `design` permission to emit early is dangerous precisely
  when the design gate cannot tell the difference, and a half-built design that
  passes is worse than a design stage that failed loudly. Any gate reading a
  stage whose disposition is unfinished (`disposition_unfinished` in
  `core/pipeline/disposition.sh`) fails closed unless it declares otherwise.
  This is now implemented: the cycle-orchestrator suppresses convergence when
  any iteration member carries an unfinished disposition (#2032).
- **`unavailable` ends the run; it is not an unfinished word.** When a stage's
  model call fails for a reason other than time, turns or a signal, the stage
  reports `unavailable`. The engine's response to that word is
  `halt_unavailable` (ADR-054 §6, enforced since #2111): the run stops there,
  marked aborted and resumable, and the runner exits 9. **(superseded 2026-10-08 by ADR-054 §4 / #1850 — now rc 1 + abort word `llm_unavailable` / `llm_rate_limited`)** So a cycle never gets
  as far as checking convergence on that call's verdict, even when part of the
  reply still read as a pass. The unfinished words are the ones the cycle
  retries; `unavailable` is not retried, so `disposition_unfinished` does not
  list it. Enforced by `tests/unit/disposition-vocabulary-test.sh` (`[ADR-063
  §4]` assertions: `unavailable` is not unfinished, and its response is
  `halt_unavailable`) and `tests/integration/cycle-gate-unavailable-aborts-run-test.sh`
  (a gate reporting a passing verdict with `unavailable` ends the run with rc 9 **(superseded 2026-10-08 by ADR-054 §4 / #1850 — now rc 1 + abort word `llm_unavailable`)**
  before gate-aggregator runs).
- **One stage, several model calls: the first failure is reported.** A stage
  that makes more than one call (spec-correspondence: one batch call, then one
  call per SPEC the batch left unjudged) reports the first non-zero exit code
  it saw, so a later call that succeeds cannot hide an earlier timeout. A stage
  that read a verdict from a call that then failed still reports that failure
  (spec-coverage). Enforced by `tests/unit/spec-correspondence-test.sh` and
  `tests/unit/spec-coverage-test.sh` (`[#2032/review]` assertions).

### 5. Two implementation shapes, chosen by the work

Both are legitimate and this ADR mandates neither:

| Shape | Example | Use when |
|---|---|---|
| **Checkpointing** | `build` — per-iteration commits, `iter N/M` | work is incremental; partial state is durable without the model's cooperation |
| **Early wind-up** | `plan`, `impact` — told the bound, asked to emit before it | the deliverable is one artifact; there is nothing to checkpoint |

Checkpointing is stronger where it applies, because it does not depend on the
model judging its own remaining budget correctly. `design` produces one artifact,
so it wants the early-wind-up shape.

**Amended 2026-10-03 (#2270): every stage that calls a model saves as it goes.**
The two shapes are no longer alternatives. Early wind-up stays where it applies,
but every stage that calls a model also declares a save-as-you-go file (an output
with `role: checkpoint`); the engine tells the model to write what it has found
there as it works. A one-artifact stage still has notes worth keeping: #1844 run
37066147994's correctness lens had traced the plugin and found real defects when
it was killed at 300 s, and the review recorded "did not run". Stages running in
parallel inside one map each get their own file — `${map_element}` in a path
resolves to the element's name. Enforced by `tests/unit/save-as-you-go-test.sh`
C1 (every model-calling plugin declares the file) and C2 (one file per map
element, and the name cannot leave the artifacts folder), and by
`scripts/lib/lint-stage-checkpoint.sh` (every declared path resolves).

**Amended 2026-10-06 (#2325): notes from an earlier outer round are labelled.**
The notes file is kept across the rounds of the outer loop (ADR-068), because
what a stage explored is still useful. But a new outer round only starts because
the checks rejected the last one, so those notes do not describe the current
state: on #2035 run 37262225813, outer round 2's test-author read round 1's
"Status: DONE" as current and wrote nothing in 45 minutes. In outer round 2 and
later, the prompt shows the notes an earlier round saved under their own heading,
saying they are from a previous round whose result was not accepted, for
reference only. The notes are not changed or deleted. Outer round 1, and a retry
inside the same round, read as before. The outermost loop publishes its round as
`ZBUILD_OUTER_ROUND` (an inner loop does not change it); when a round's first
prompt is built, the engine records in `<notes>.rounds` how long the notes file
was, and everything before that point belongs to earlier rounds. Enforced by
`tests/unit/checkpoint-outer-round-test.sh` O1 (each stage knows its outer round,
nested loops included), O2 (round 2 labels round 1's notes), O3 (round 1 and its
retries are unchanged), O4 (a retry inside round 2 reads its own notes as before)
and O5 (the notes file is kept).

### 6. Carry-forward rides on the existing summary channel

#1986 has every stage publish a summary and every following stage ingest them. A
partial attempt's summary is how the next attempt learns what the last one got
through. **Do not build a second channel for this.**

**Amended 2026-10-03 (#2270):** when a stage ends cut off (`timed_out` or
`out_of_turns`), the summary later stages read carries what it saved, marked as
unfinished and unchecked; a stage that finished does not get its notes appended.
A review lens cut off this way puts its notes in its result (`data.partial_notes`),
and the review report shows them under that lens. Enforced by
`tests/unit/save-as-you-go-test.sh` C3/C4 and
`plugins/agent/review-lens/tests/review-lens-partial-notes-test.sh` N1–N3.

## Consequences

- **An unfinished stage stops being decorative.** `timed_out` and `out_of_turns`
  (which #2187 put in place of the retired `exhausted`) route to a retry, and
  ADR-029's timeout escalation now runs for an LLM stage; before, it never did.
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
5. **`build`** — already checkpointed; confirm it reports `out_of_turns` when the
   iteration budget is spent rather than falling out silently.

The discriminating test, per stage: kill it at its bound and assert the next
attempt starts from something. A stage that passes that with the mechanism
removed is not testing it — the failure mode of every prior fix in this area.
