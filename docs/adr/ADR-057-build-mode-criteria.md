# ADR-057: Build Mode — when work is dogfooded, built by hand, or needs a decision first

**Status:** Accepted (2026-08-12)
**Date:** 2026-08-12
**Issue:** #1768
**Amended:** 2026-08-22 (#1918) — §2 gate 3 narrowed to account for the human merge gate, and gate 3b added for a diff that cannot be pushed at all
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

### 2. The gates, in order — first match wins

Gates 1, 2, 3, 3b, then 4 as the default. Gate 3b was added by the #1918 amendment below and is numbered `3b` rather than `5` deliberately: gate 4 is the fallthrough and issues already cite it by number, so nothing may be inserted after it.

**Gate 1 — Is the decision already made? → `Design Decision needed`**

The work requires resolving a conflict between accepted documents, choosing a vocabulary, or settling a contract shape. A pipeline run cannot decide such a thing; it will pick one option and present it as settled.

*Worked example:* #1768 turned out to rest on ADR-046 and ADR-055 disagreeing about whether `source: artifacts` existed, with neither marked superseded and ADR-055 not referencing ADR-046 at all. No run could have resolved that.

**Gate 2 — Does the run grade itself with the code being changed? → `By-hand`**

Mechanically decidable, not a judgement call. Any of:

- the change touches a file in the hot-reloaded contract-reader set. **Compute it, do not copy it:** `_runner_contract_lib_closure` in `core/pipeline/runner.sh` derives the transitive closure from `_RUNNER_CONTRACT_LIB_ENTRYPOINTS`. At time of writing that resolves to eight files under `scripts/lib`, but the list is derived and will change.
- the change alters how verdicts or dispositions are read.
- the change alters the template or the stage roster — the running pipeline is the artifact being modified (ADR-047).

**Gate 3 — Would a defect a *reviewer would not catch* stop the next run from starting? → `By-hand`**

The blast-radius gate, and the one no prior document names. `_contract_validate_pipeline` runs in `runner.sh:main()` after `load_template` and **before the first stage dispatches**; in `enforce` mode it writes `status: preflight_failed` and returns rc=2. A wrong change there halts every subsequent run before intake — including the runs you would use to fix it. Same class: `install.sh`, the template loader, `runner.sh:main()`, the event bus.

*Worked example:* #1768 opens source validation from 17 of 50 inputs to all 50. Ten inputs fail under the wider check before the accompanying fixes. A mistake there is not one bad PR; it is a pipeline that will not start.

> **Amended 2026-08-22 (#1918) — the gate must count what stands in front of a merge.**
>
> As first written, gate 3 asked *"would a defective merge stop the next run from starting?"* and named no gate in front of one. A defect does not reach `main` unopposed: `allow_auto_merge=false` on this repository, and every PR of the #1912–#1917 wave was merged by a human after CI went green. A defect must clear **both** to land.
>
> That does not retire the gate; it narrows it. Gate 3's named examples are defects **subtle enough to survive review** and *then* brick every subsequent run — a validator that is one predicate too strict, a loader that mis-parses a shape nothing in CI exercises. A change to the same files that a reviewer would plainly catch is not that, and gate 3 as originally worded did not distinguish them, so it **over-fired**: it cost #1919 an incorrect `By-hand` before the marking was re-derived.
>
> Read gate 3 as: *would a defect that CI is green on and a reviewer would sign off halt the next run before intake?* If a competent reviewer would catch it, the answer is no, and the work falls through to gate 4.

**Gate 3b — Can the diff be pushed at all? → `By-hand`**

*Added 2026-08-22 (#1918).* A mechanical bar, not a judgement — and in practice the cheapest of the five to check, since it is one glob against the diff.

The App token the dogfood pushes with **lacks the `workflows` permission** (#1780, open). Any diff touching `.github/workflows/**` is rejected at the **final** push, after the full wall-clock and token spend — #1761 lost 2h50m to exactly this. That is a hard mechanical bar to dogfooding, and it matched **none** of gates 1–4: the run grades itself fine, a defective merge is harmless, no decision is pending. The work simply cannot land by that route.

*Worked examples:* #1918 (this amendment's own issue) touches `.github/workflows/zbuild-pipeline.yml` to exclude scratch from the artifact upload; #1632 touches the workflows for its own reasons. Neither could name a gate under §3 before this one existed.

When #1780 closes, gate 3b closes with it. Until then, §3's requirement that every non-`Dogfood` marking name its gate is unsatisfiable without it.

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
- Gate 3 names a real hazard that three prior documents missed — and, as amended, no longer fires for defects the human merge gate would catch.
- Gate 3b gives §3 a gate to name for the one class of work that provably cannot be dogfooded.
- ADR-036's stale advice stops sending work to the slow path unnecessarily.

**Negative / costs**
- Gate 3b is a workaround with an expiry: it encodes a token-permission defect (#1780) as a Build Mode rule. It must be removed when #1780 closes, and nothing enforces that it will be.
- The field still has no automated consumer; nothing enforces these gates. That is deliberate — inventing a consumer for an advisory field would be scope no one asked for — but it means the gates rely on being read.
- 204 blank items are not triaged by this ADR. It defines the target state; the backfill is separate work.

## Implementation Notes

No code. Verification is `npm run lint` (which runs the docs checks) plus re-deriving the gate-2 file set with `_runner_contract_lib_closure` rather than trusting the count quoted in §2.

**Re-derive the gate-2 set; never copy it — and derive the closure, not the array.** The two are different numbers and reading the wrong one is the easy mistake: `_RUNNER_CONTRACT_LIB_ENTRYPOINTS` (`core/pipeline/runner.sh`) lists **six** basenames, but the gate is about `_runner_contract_lib_closure`, which follows same-directory `source` lines from each and resolved to **eight** at #1918 (2026-08-22):

```
acceptance-block.sh  acceptance-coverage.sh  acceptance-negctl.sh
acceptance-reachability.sh  env-scrub.sh  impact-prefilter.sh
merge-base.sh  shape-floor.sh
```

All eight are under `scripts/lib`. Nothing in `core/` is in the set, so `core/pipeline/verdict.sh`, `core/plugin-registry/lifecycle.sh` and `core/router/route.sh` are **not** self-graded and gate 2 fires for none of them — which is what let #1918 change the dispatch seam without tripping it. Run it:

```bash
bash -c 'source core/pipeline/runner.sh 2>/dev/null; _runner_contract_lib_closure "$PWD/scripts/lib"'
```

**Checking gate 3b:** `git diff --name-only <merge-base>.. -- '.github/workflows/**'` — any output means `By-hand` until #1780 closes.

**Checking gate 3's merge-gate premise:** `gh api repos/:owner/:repo --jq .allow_auto_merge` — `false` means a human stands in front of every merge, which is what narrows the gate.

## References

- `.github/workflows/zbuild-pipeline.yml` — the engine-from-`main` install (§1)
- `core/pipeline/runner.sh` — `_runner_contract_lib_closure`, `_runner_refresh_contract_snapshot`, `_runner_design_targets_contract_lib` (§2, §5)
- ADR-036 §"Self-hosting note" (superseded, §5), ADR-047 Implementation Notes, #1819 Sequencing
- #1783 (self-host snapshot refreshed per member), #1305 (the non-convergence that motivated engine-from-`main`), #963 (the guard #1783 inverted)
- #1780 (App token lacks `workflows` permission — the defect gate 3b encodes), #1761 (2h50m lost to it), #1918 (the amendment), ADR-058 (the engine write boundary, whose own workflow edit is gate 3b's worked example)
