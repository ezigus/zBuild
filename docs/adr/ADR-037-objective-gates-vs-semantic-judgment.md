# ADR-037 — Objective gates vs. semantic judgment (PR-handoff + template merge policy)

**Status:** Accepted (2026-06-19)
**Related** — dispositions below are **PLANNED** (declared in §6, executed in I13 / #979); **this PR edits no existing ADR**:
- peer: ADR-038 (adversarial multi-lens review report)
- supersede-planned: ADR-022, ADR-026
- amend-planned: ADR-036, ADR-019, ADR-031, ADR-013, ADR-021, ADR-030, ADR-020, ADR-015
- promote-planned: ADR-033
- kept (unaffected): ADR-029, ADR-017, ADR-003, ADR-027, ADR-034
**Issue:** #967 (EPIC #966, I1)

## Context

zBuild's quality machinery accreted into a nested-cycle stack — `design_impact_cycle`,
`build_review_cycle`, `build_test_cycle`, the ADR-036 acceptance-teeth lattice, four `cq-*` stages, and
review verdict-coercion. Each dogfood failure added a gate, a feedback edge, or an ADR amendment, and
the next dogfood found a new gap. The growth never converged.

A four-lens analysis (issue-inventory, ADR-landscape, adversarial-critique, memory-audit) found the
root cause: **the pipeline tries to mechanically *prove semantic properties*** — "this test tests the
right thing," "this change is wired in," "this change is complete," "the docs were updated." Those are
judgment questions. Forced through mechanical proxies (SPEC tagging/classification, `WIRING`
declarations, ablation ceremonies) they become proxies an LLM author satisfies *syntactically while
missing the intent* (e.g. #844: a `[SPEC-7]` tag present but asserting the wrong behavior; the gate
green).

Two corrections from that analysis are load-bearing here:
- The **deterministic checks are NOT proxies** — `negctl` (a test must fail at the merge-base baseline),
  reachability ablation (revert the wiring → a test must break, ADR-036 §Amendment #956), and the
  shape-change/golden-order floor are mechanical and un-gameable. They catch this repo's signature bugs
  (tautological tests, inert wiring). **Keep them.** Coverage-*delta* does not substitute for `negctl`.
- **`cq-cycle` is an inert no-op today** (it writes `"findings":[]`; 6 of 7 lenses do not exist), but the
  cq lens *concept* is the real value — those lenses ARE the semantic review.

The disease is the **BLUR**: mechanical checks bundled with judgment (`compound_quality` mixes
deterministic preflight with the cq-cycle lenses), and a mechanical gate result *coercing* a semantic
verdict (the acceptance-gate downgrading `review`). The cure is **separation, not deletion.**

## Decision

Split pipeline quality enforcement into two strictly separated layers, and stop self-certifying merges.

### 1. Objective gate layer (mechanical, deterministic, **no LLM**, **hard-blocks merge**)

The only stages that may block the pipeline. Each is deterministic, auditable, and contains no
LLM/router call:

- full test suite green
- lint / shellcheck
- `negctl` baseline-fail (each changed-behavior test fails at the merge-base, passes at HEAD)
- reachability ablation (revert the wiring → a test must break) — the mechanism from ADR-036's #956
  amendment, retained but **de-ceremonied** (mechanically-derived targets; no `WIRING`/SPEC grammar)
- shape-change / golden-order floor (a stage-set / golden shape change requires its pinning tests to be
  touched) — salvaged from the deterministic floor in the `impact` plugin
- coverage floor (the existing statement floor)
- scope-adherence (files the design/plan named were actually changed)

Coverage-*delta* (new-code execution) is emitted as a **report signal**, never a block — it proves a
test *runs* new code, not that the test *fails without* it; only `negctl` proves the latter.

### 2. Semantic layer is advisory only

All semantic judgment moves to a single `review` stage that produces an advisory **merge-readiness
report** — defined in ADR-038. It never hard-gates and never coerces a verdict.

### 3. The invariant (the un-blur)

> **No objective gate is an LLM; no semantic lens hard-blocks merge.**

This is the rule that keeps the two layers from re-merging. Tests assert it directly: the objective-gate
stage contains no LLM/router call; the review stage emits a report and never blocks.

### 4. Merge policy — a per-template knob

`merge_policy` is a template field (composable per ADR-016/ADR-027), values:

- `auto_unless_flagged` (**default**) — auto-merge when every objective gate is green AND the review
  report flags nothing top-severity / lenses agree; otherwise escalate to a human PR.
- `auto` — merge whenever objective gates are green; the report is informational only.
- `manual` — always stop at a PR with the report attached; a human merges.

A template that omits `merge_policy` gets `auto_unless_flagged`.

### 5. PR-handoff — the pipeline does not self-certify a merge

The pipeline's terminal success state is "objective gates green → PR opened with the report attached."
No stage upgrades, coerces, or self-certifies a *merge authorization*; merge happens only via
`merge_policy`. The fail-closed principle of ADR-019 survives, re-expressed as the objective
suite-green gate (a non-green suite halts before review) rather than as verdict coercion.

### 6. Supersede / amend map (declared here; **executed in I13 / #979**, not by this ADR)

This ADR is authored additively and does not edit other ADRs. The retirement step executes:

| ADR | Action under this design |
|-----|--------------------------|
| ADR-022 | **Supersede** (the LLM-graded verdict role is gone; convergence uses objective suite-green) |
| ADR-026 | **Supersede** — the review-remediation `build_review_cycle` is removed. NB: its #951 amendment (the `acceptance-gate.gate_result → build` feedback edge + `max_iterations` 2→3) goes *with* the cycle — intended; I13 must not silently preserve that edge. |
| ADR-031 | **Amend** (NOT full supersede) — keep the minimal acceptance-block test↔change addressing that `negctl` needs; strike the test-first-by-convention + don't-weaken-by-process clauses and the SPEC `[change]`/`[guard]` classification. Whether any acceptance-block *format* survives at all depends on #971's mechanical target derivation (see Limitations); if targets become fully diff-derived, this rises to supersede. |
| ADR-036 | **Amend** — keep `negctl` + reachability + shape-floor + minimal test↔change addressing; strike the coverage-gate ceremony, SPEC `[change]`/`[guard]` classification, and `WIRING` grammar |
| ADR-019 | **Amend** — keep fail-closed *as the objective suite-green gate*; strike verdict-coercion §3/4/5/7 (only after the objective gate is live, else reopens #485) |
| ADR-013 | **Amend** — strike the `impact` / `test_assessment` / `acceptance-gate` / `cq-*` rows |
| ADR-021 | **Amend** — keep the cycle *framework*; strike the named `design_impact_cycle` / `build_review_cycle` and the `test_assessment` `until:` source |
| ADR-030 | **Amend** — keep the scope layers (Layers 1–3; promote scope-adherence to a hard gate); strike **Amendment v2 only** (#842, the impact-v2 / `design_impact_cycle` discovery contract); fold the R3 assertion-integrity charter into a review lens |
| ADR-020 | **Amend** — strike the LLM-verdict-stage edges |
| ADR-015 | **Amend** — strike the dead `impact` / `test_assessment` renderer registrations (the renderers live in `scripts/lib/artifact-render.sh`; their declarations are in ADR-015/ADR-022 amendments) |
| ADR-033 | **Promote** — the typecheck gate becomes a first-class objective gate |
| ADR-029, ADR-017, ADR-003, ADR-027, ADR-034 | **Keep** (unaffected) |

## Consequences

- The whack-a-mole stops by construction: semantic completeness is no longer chased through mechanical
  proxies; it is routed to diverse judgment (ADR-038) plus the human at the merge boundary.
- The deterministic teeth (`negctl`, reachability, shape-floor) survive — the protections this repo bled
  over are not lost; only the ceremony and the LLM theater around them are.
- The pipeline becomes a *PR producer*, not a *merge authority*. Daemon/high-volume autonomy is
  preserved by `merge_policy: auto*`; high-stakes templates can opt to `manual`.
- The `cq-*` stages, the `impact` LLM cycle, `test_assessment`, the review verdict-coercion, and the
  review-remediation loop are removed (I13 / #979); the cq lenses are *rehomed* into the review (ADR-038).

## Implementation Notes (EPIC #966)

Delivered as the additive-first, subtractive-last rollout of EPIC #966, via a parallel
`config/templates/simple.yaml` template (A/B-proven, then cut over):

- **#968** — `simple.yaml` skeleton + the `merge_policy` field (default `auto_unless_flagged`).
- **#969–#971** — the objective gate layer: suite-green + lint (#969 ✓ delivered), coverage-floor + scope-adherence
  (#970 ✓ delivered — in `simple.yaml` only, objective-gate repositioned to after `test` so post-build
  artifacts are available; coverage-floor and scope-adherence gates added. `standard.yaml` is left
  unchanged until the cutover, #978/#979),
  `negctl` + reachability + shape/golden-order floor de-ceremonied (#971).
- **#972–#974** — the semantic review (ADR-038): report stage (#972), per-lens evidence (#973), rehomed
  cq + persona lenses (#974).
- **#975–#976** — `merge_policy` knob + escalation (#975); build/test convergence on objective
  suite-green, retiring `test_assessment`-as-verdict (#976).
- **#977–#979** — A/B-prove real issues through `simple.yaml` (#977), flip the default (#978), then
  hand-retire the old lattice + execute the §6 supersede/amend map + tombstones (#979).

**Ordering guard:** the objective suite-green gate (#969) MUST be live before review coercion is struck
(#979), or the #485 "green merge on failing tests" hole reopens.

## Limitations / future work

- The human-gate (`auto_unless_flagged` escalation) can decay into rubber-stamping if the report is
  almost always "ready"; the escalation must reserve human attention for genuine top-severity / lens
  disagreement, not annotate every PR.
- `merge_policy: manual` reintroduces a human bottleneck for high-volume/daemon mode by design — choose
  it per template, not globally.
- The cq lens *content* quality is out of scope here; ADR-038 governs how the lenses run, not what each
  asserts.
- **Open dependency for #971:** striking the `WIRING:` grammar (ADR-036 #956) requires a mechanical way
  to derive the reachability-revert target from the diff alone. That derivation must be designed and
  proven in #971 *before* the `WIRING:` declaration is retired — until then the landed #956 mechanism
  stays as-is. The same question applies to how `negctl` derives the test↔change pairing without the SPEC
  grammar (ties to the ADR-031 amend above).
