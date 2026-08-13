# ADR-057: Build Mode — when work is dogfooded, built by hand, or needs a decision first

**Status:** Accepted (2026-08-12)
**Date:** 2026-08-12
**Issue:** #1768
**Amends:** ADR-036 (§"Self-hosting note" — its rule that grammar-extending changes must be hand-landed was superseded by #1783 and never updated; see §5)
**Related:** ADR-023 (install isolation), ADR-047 (stage-agnostic mechanics — its own dogfood carve-out, §5), ADR-050 (prior-work reuse), ADR-055 (inter-stage data contract v2)

## Context

The zBuild Roadmap project carries a `Build Mode` field with three values: `Dogfood`, `By-hand`, `Design Decision needed`. Current distribution: **243 Dogfood, 37 By-hand, 16 Design Decision needed, 204 blank.**

**Nothing in the repository reads this field.** It is advisory — a signal to whoever picks the work up.

No document says when each value applies. Three criteria exist, scattered across two ADRs and an issue, none generalised:

- **ADR-036, "Self-hosting note"** — *"a dogfood that uses the new grammar cannot be validated by the installed (pre-`WIRING`) engine in the same run … Such grammar-extending changes are hand-landed, then installed."*
- **ADR-047, Implementation Notes** — *"a 'remove/rename a stage' change cannot be dogfooded through the pipeline itself — the running pipeline is the artifact being modified."*
- **#1819 (Phase 0 epic)** — *"it modifies the code that decides whether a run succeeded, so a run making the change reports success regardless."*

The consequence is that a marking cannot be checked. #1768 was marked `By-hand`; the marking was correct under §2 gate 1 and gate 3 below, and nothing recorded that, so it read as arbitrary and was queried. A field that carries a verdict without its reason is indistinguishable from a guess.

## Decision

### 1. First, the fact everything else follows from

**A dogfood run does not execute the code being changed.**

`.github/workflows/zbuild-pipeline.yml` clones `main` into `$RUNNER_TEMP`, *outside the workspace* — its own comment says *"so the pipeline cannot edit it"* — installs from there, invokes the shim, and **fails rather than falling back to the checkout copy**. Plugins resolve from the installed tree too. This was deliberate: an earlier version installed from the checkout, so a build stage editing `core/` changed the machinery evaluating its own next stage (#1305 never converged — the same accessors moved four times in five iterations).

So the question is **not** "can the run test this change?" — it almost never can; **CI does that**. The two questions that matter are whether the run's own verdicts can be trusted, and what a bad merge costs.

### 2. The four gates, in order — first match wins

**Gate 1 — Is the decision already made? → `Design Decision needed`**

The work requires resolving a conflict between accepted documents, choosing a vocabulary, or settling a contract shape. A pipeline run cannot decide such a thing; it will pick one option and present it as settled.

*Worked example:* #1768 turned out to rest on ADR-046 and ADR-055 disagreeing about whether `source: artifacts` existed, with neither marked superseded and ADR-055 not referencing ADR-046 at all. No run could have resolved that.

**Gate 2 — Does the run grade itself with the code being changed? → `By-hand`**

Mechanically decidable, not a judgement call. Any of:

- the change touches a file in the hot-reloaded contract-reader set. **Compute it, do not copy it:** `_runner_contract_lib_closure` in `core/pipeline/runner.sh` derives the transitive closure from `_RUNNER_CONTRACT_LIB_ENTRYPOINTS`. At time of writing that resolves to eight files under `scripts/lib`, but the list is derived and will change.
- the change alters how verdicts or dispositions are read.
- the change alters the template or the stage roster — the running pipeline is the artifact being modified (ADR-047).

**Gate 3 — Would a defective merge stop the next run from starting? → `By-hand`**

The blast-radius gate, and the one no prior document names. `_contract_validate_pipeline` runs in `runner.sh:main()` after `load_template` and **before the first stage dispatches**; in `enforce` mode it writes `status: preflight_failed` and returns rc=2. A wrong change there halts every subsequent run before intake — including the runs you would use to fix it. Same class: `install.sh`, the template loader, `runner.sh:main()`, the event bus.

*Worked example:* #1768 opens source validation from 17 of 50 inputs to all 50. Ten inputs fail under the wider check before the accompanying fixes. A mistake there is not one bad PR; it is a pipeline that will not start.

**Gate 4 — Otherwise → `Dogfood`.**

This is the default and should remain the common case.

### 3. Record the reason, not only the value

A Build Mode value carries a verdict with no argument. Every non-`Dogfood` marking states, in one line in the issue body, which gate it matched and why:

> **Build Mode: By-hand** — gate 3: changes the pre-flight validator, which runs before the first stage; a bad merge halts every subsequent run before intake.

`Dogfood` needs no line, being the default.

### 4. Blank is not a value

204 items are blank. Blank means **not yet triaged**, not "dogfood". An issue reaching `Up Next` has Build Mode set.

### 5. ADR-036's self-hosting note is superseded

ADR-036 states that grammar-extending changes must be hand-landed because the contract reader is pinned to the install. **#1783 removed that constraint and the note was never updated.** `_runner_refresh_contract_snapshot` deliberately carries no once-guard, and `core/pipeline/runner.sh:996-999` says why:

> the whole point is that the snapshot tracks the tree as build changes it. #963's guard implemented the opposite property — "a mid-run edit cannot mutate what the readers parse" — which is exactly what makes a dogfood of a grammar change unlandable.

So a contract-grammar change **is** dogfoodable. It is also **self-grading** — the run's gates read the code build just wrote — which is why it lands under gate 2 as `By-hand` by default rather than being forbidden. The engine surfaces the condition: `_RUNNER_SELF_GRADE_REASON` is emitted once per run so the operator can see it happened.

## Consequences

**Positive**
- A marking can be checked against a rule instead of taken on trust.
- Gate 2 is computable rather than argued.
- Gate 3 names a real hazard that three prior documents missed.
- ADR-036's stale advice stops sending work to the slow path unnecessarily.

**Negative / costs**
- The field still has no automated consumer; nothing enforces these gates. That is deliberate — inventing a consumer for an advisory field would be scope no one asked for — but it means the gates rely on being read.
- 204 blank items are not triaged by this ADR. It defines the target state; the backfill is separate work.

## Implementation Notes

No code. Verification is `npm run lint` (which runs the docs checks) plus re-deriving the gate-2 file set with `_runner_contract_lib_closure` rather than trusting the count quoted in §2.

## References

- `.github/workflows/zbuild-pipeline.yml` — the engine-from-`main` install (§1)
- `core/pipeline/runner.sh` — `_runner_contract_lib_closure`, `_runner_refresh_contract_snapshot`, `_runner_design_targets_contract_lib` (§2, §5)
- ADR-036 §"Self-hosting note" (superseded, §5), ADR-047 Implementation Notes, #1819 Sequencing
- #1783 (self-host snapshot refreshed per member), #1305 (the non-convergence that motivated engine-from-`main`), #963 (the guard #1783 inverted)
