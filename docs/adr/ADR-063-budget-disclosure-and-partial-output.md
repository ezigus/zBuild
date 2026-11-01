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

**Amended 2026-10-12 (ADR-067 §8): the engine states the budget, once, for every stage.**
The per-stage budget helpers and the shared `stage_budget_note` are removed. The engine
states each stage's budget in its **Rules for this stage** block: seconds and turns per
model call, the same for every stage — the engine needs no declaration from a stage about
whether or how it calls a model — read from the same resolvers the router enforces (`scripts/lib/stage-limits.sh`, one copy
for both). A stage with no turn limit is told so. Enforced by
`tests/unit/stage-prompt-contract-test.sh` R3 and `tests/unit/save-as-you-go-test.sh` C1.

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
  that makes more than one call (test-author's check of its assertions, was
  spec-correspondence: one batch call, then one call per SPEC the batch left
  unjudged) reports the first non-zero exit code it saw, so a later call that
  succeeds cannot hide an earlier timeout. A stage that read a verdict from a
  call that then failed still reports that failure (design's coverage call, was
  spec-coverage). Enforced by `tests/unit/test-author-correspondence-test.sh` and
  `tests/unit/design-coverage-test.sh` (`[#2032]` assertions).

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

**Amended 2026-10-12 (ADR-067 §8): every stage's notes file is the engine's.**
No manifest declares a `role: checkpoint` output any more, and the separate notes
block and its "previous round, not accepted" label are gone (#2325's rule is
withdrawn: a stage's latest notes are its latest output, ADR-068 §8). Every stage has
a notes file, `artifacts/notes/<stage>[-<element>].md` (a map element its own); the
engine names it in the stage's rules, lists it for every later stage under Previous
work, and gives the stage its own notes back in full there. Enforced by
`tests/unit/stage-prompt-contract-test.sh` R1, `tests/unit/save-as-you-go-test.sh` C3,
`tests/unit/stage-blocks-dispatch-test.sh` D4 and
`tests/unit/router-permissions-grant-coverage-test.sh` SPEC-2 (the model may write it).

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

### Amendment (2026-10-15) — the engine bounds the whole stage

`router.timeout_s` bounds one model call; nothing bounded a stage, so a stage that loops or a script
that hangs ran forever, and the engine cannot trust a stage to stop itself. Each stage now has a
whole-stage limit: the template's per-stage `timeout_s:` (directly under the stage, not under
`router:`), 900 seconds (15 minutes) when unset. A stage that needs more says so in the template: the
limit covers every model call, check and round inside the stage, plus a few minutes (simple.yaml:
build 3600, test 2700, design 2700, test-author 3780, acceptance-gate 2700).

- **What the engine does at the limit** (`plugin_hook_call`): it records the limit
  (`runtime/stage-time-limit.<stage>`), emits `stage.time_limit.reached`, and stops the stage and
  everything it started — TERM, then KILL. The stage's outcome is `timed_out`; whatever it saved as it
  went is kept (§2), and the loop's own rules decide what happens next.
- **The stage is told its limit** in its rules (§1): "The whole stage has N seconds."
- Every dispatch arm, a `map:` member included, reads the same limit
  (`scripts/lib/stage-time-limit.sh`, from the loaded template).

Enforced by: `tests/integration/stage-time-limit-test.sh` S1–S5.

## Amendment (2026-10-29): a map group's rounds fit its stage limit; a cut-off lens says so

A map group runs its members `max_parallel` at a time, so its stage limit must hold every round:
`ceil(members / max_parallel) × per-call limit ≤ timeout_s`. The review lenses get the per-call
limit build gets (they were stopped at 300 s on #1801 and #1944 while still reading) and run in
one round. Enforced by `tests/unit/map-group-budget-test.sh`.

A lens cut off by its time limit says it ran out of time — not that the model call failed — and
its summary carries what it noted so far, marked partial (§6: the summary is what later stages
and the status comment read). Enforced by
`plugins/agent/review-lens/tests/review-lens-partial-notes-test.sh` N6, N7.

## Amendment (2026-11-01, #2443): notes are a hand-off; a cut-off call's steps reach the next try

On #1754 (run 41249802310) build's 3 tries were each cut off at 15 minutes. Each started over, read the
same files again and wrote no notes, so the next try was given nothing of what the last had found — though
the engine had kept every step the call made (#2139).

- Every stage's notes rule now says to write them as a hand-off: someone starting fresh, without the
  stage's context, must be able to pick up from them.
- When a model call is cut off at its time limit, the engine lists the steps it recorded — each file read,
  command run and sentence said, the newest that fit what the prompt shows of it (at most 60) — in `artifacts/notes/<stage>.cut-off.md`, beside the
  notes. The stage's own Previous work gives the list to its next try, saying the call was cut off; no
  other stage is given it. A call that is not cut off removes the list, so it is only ever about the call
  just before. This is the notes channel (§6), not a second one, and the list is not the stage's notes:
  writing it is not progress (ADR-054 §6a).
- Each try's raw record of a failed call is its own file, named by round and try
  (`<stage>-round<r>-try<n>-error.raw-claude-output.json`), not overwritten by the next try.
- Build's prompt says to write its notes first and add each finding before its next step.

Enforced by `tests/unit/cut-off-hand-off-test.sh` H1–H4; `tests/integration/cut-off-steps-test.sh` C1–C4;
`tests/unit/build-test-is-wrong-test.sh` W5.
