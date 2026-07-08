# ADR-047 — Stage-agnostic pipeline mechanics (the mechanics name no stage)

**Status:** Accepted (2026-07-08)
**Amends:**
- ADR-013 (canonical-stage list — demoted from an engine-owned closed enumeration to a manifest-derived registry/lint artifact; membership + order are re-expressed as fail-closed, manifest-derived load-time preflights)
- ADR-019 (fail-closed — re-expressed generically: an unresolved leaf or an unsatisfied upstream-input **errors at load**, for any repo's stages)
- ADR-040 (§7 marker-discovery — extended from must-pass-set discovery to verdict-channel + capability metadata; the same "discovered, not hardcoded" principle)
- ADR-042 (stage portability — completes the thesis: resolution is already role-then-id/stage-agnostic; the remaining mechanics — verdict-read, cycle capability decisions, membership/order validation, post-stage hooks — become stage-agnostic too)
**Related:** ADR-032 (per-repo prompt overrides — mechanism preserved), ADR-020 (inter-stage data contract), ADR-039 (parallel groups), EPIC #966, EPIC #1277.

## Context

Marker-driven discovery (ADR-040 §7) and uniform role-then-id resolution (ADR-042)
established that the pipeline **mechanics** — the generic engine that runs
leaf/parallel/cycle, dispatches stages, and converges — can be **stage-agnostic**:
they read *declared data*, not stage *names*. But the principle was applied only to
the gate-aggregator's must-pass set and to plugin resolution. The rest of the
mechanics still embedded specific stage identities:

- **A closed stage vocabulary** — `_ZBUILD_CANONICAL_STAGES` (`core/pipeline/template.sh`)
  is an engine-owned list used to (a) reject any unknown stage id and (b) enforce a
  canonical stage *order*. `_LC_STAGE_IDS_TO_CHECK` (`scripts/lib/lint-contract.sh`)
  is a hand-curated subset.
- **Per-name verdict special-cases** — `verdict.sh` reaches into each stage's artifact
  and infers its verdict, branching on the names `design`, `build`, `security-lens`.
- **Per-name cycle capability decisions** — `cycle-orchestrator.sh` branches on `test`,
  `build`, `test_assessment` to pick a failure-count source / empty-diff policy /
  feedback-digest format.
- **Per-name runner behavior** — `runner.sh` splices a scope override only for `intake`,
  and carries a hardcoded fallback stage list.
- **Prompt-side leak** — a stage's shipped base prompt named the repo (`"...for zBuild"`),
  and a per-repo overlay enumerated zBuild's closed stage set.

The consequence: adding or retiring a stage required *engine* edits and per-stage ADR
amendments. That is a symptom, not a necessity.

## Decision

The mechanics own a small **closed set of composition operators** and know **nothing**
about any stage. Stages are pure **data + plugins**. Everything a mechanic needs to make
a flow decision is **declared** in a manifest (or the template) and **discovered** at
runtime — never hardcoded as a stage name in `core/pipeline/`.

### 1. The closed operator set (the only thing the mechanics enumerate)

The mechanics enumerate exactly four composition operators, and nothing else:

- **`leaf`** — a single dispatched stage.
- **`sequence`** — implicit `flow:` order.
- **`parallel`** — a `type: parallel` group (ADR-039).
- **`cycle`** — a `type: cycle` group with convergence (ADR-021/045).

Flow *decisions* these operators make — `exit_when` convergence, `route_back`, parallel
join/aggregate — read **declared data only**. No operator, and no decision it makes,
references a stage id.

### 2. The 3-bucket boundary

Every unit of the pipeline is exactly one of:

- **Core mechanics** — the operator set + the flow decisions above. Zero stage names.
- **Utilities** — shared services stages depend on (redaction, state I/O, event bus,
  verdict normalization, router, scope). No ordering role.
- **Stages** — work units (data + plugin) that emit verdicts/artifacts. A stage's verdict
  *consumed by* a mechanic (e.g. a cycle's `exit_when` reading a stage's verdict) is the
  **correct seam**, not a violation. `design-gate`, `gate-aggregator`, `shape-floor`,
  `secret-scan`, `acceptance-gate`, `review-aggregator`, and the lenses are all **stages**.

"Drives order" is **not** a bucket: a stage does work and emits a verdict; a *mechanic*
reads that verdict to drive flow. The two are distinct roles at a clean seam.

### 3. Verdict is a canonical PUSH channel (not per-name PULL)

A stage **reports** its normalized verdict to one **canonical verdict channel** on exit.
The verdict utility (`verdict.sh`) is a generic normalizer: it reads the channel and
overlays only the rules a stage cannot self-report — **rc≠0 → fail (always wins)** and
**channel missing/malformed → warn**. No per-name branches; no "where to read this
stage's verdict" metadata, because the channel is always the same place.

A stage's **work-product artifact ≠ its verdict-channel**. A stage whose primary output
is non-JSON (e.g. `design.md`) writes a small separate verdict JSON — this is the
**normal** contract, not a special-case sidecar.

### 4. Capability flags (declared, not name-inferred)

Where a mechanic needs a stage-specific capability, the stage **declares** it and the
mechanic reads the flag:

- `provides_detailed_failure_count` — the cycle prefers a structured failure count over a
  generic fail.
- `produces_commits` + `empty_diff_legitimate` — the cycle's no-committed-changes policy.
- `feedback_fields` — how a stage's feedback is formatted into the cycle digest.

### 5. Membership + order are fail-closed, manifest-derived preflights

The engine-owned `_ZBUILD_CANONICAL_STAGES` is **demoted** to a manifest-derived
registry/lint artifact. Its two enforcement roles are re-expressed as **fail-closed**
load-time preflights, derived from installed manifests:

- **Resolvability** — every leaf in a template `flow:` must resolve to a plugin
  (`resolve_stage_plugin`, role-then-id, ADR-042). An unresolved leaf **errors at load**
  (non-zero rc, actionable message naming the id). Replaces "reject unknown id".
- **Upstream-input satisfaction** — for every manifest declaring `inputs[].source: stage:X`,
  `X` must appear **earlier in the resolved flow order** (ADR-020 data-dependency DAG). An
  unsatisfied/late dependency **errors at load**. Replaces canonical-order.

These **error**, not warn: the checks they replace are hard load gates, so the
replacements must be at least as strict, or the change that removes the fence silently
downgrades a load-time guarantee to a runtime surprise. The only silent case is a stage
that declares **no** inputs (nothing to check).

**Residual (accepted).** The old order-check flagged *two independent stages swapped*; the
data-dependency check does not (no declared dependency = no constraint). This is never a
correctness failure — a swap that violates no declared data dependency is, by definition,
order-independent.

### 6. Prompts are target-agnostic; the generic principle stays

A stage's always-present base prompt is stage-specific and ships in its plugin, and it
must be **target-agnostic** — it names no repo. The generic enumerated-set /
absence-by-omission scope-discovery wisdom is valuable and stays (it names no stage). The
per-repo prompt-override **mechanism** (ADR-032/033) is preserved — it is how any target
repo declares genuine domain-specific enumerations (ADR-032); a repo whose stage set is
open simply carries no roster enumeration in its overlay.

## Consequences

- Adding or retiring a stage is a **template + plugin change with zero edits under
  `core/pipeline/`**. #979 (retire the old lattice) collapses from per-stage engine
  surgery to **data deletion**.
- A **fictitious-stage harness** — add a plugin with a fictitious id + a fixture template,
  assert the mechanic dispatches/validates/converges/reads-its-verdict with
  `git diff --exit-code` over the mechanic file showing **zero changes** — is a permanent,
  un-gameable CI guard that no stage name re-enters the mechanics.
- The engine is **repo-agnostic by construction**, not by convention: nothing under
  `core/pipeline/` names a zBuild stage, and no shipped prompt names zBuild.
- This **completes** ADR-039/040/042 rather than reversing them; the only genuine reversal
  is ADR-013's "closed, engine-owned enumeration", superseded here by the manifest-derived
  registry + fail-closed preflights.

## Implementation Notes (EPIC #1277)

Landed across child issues, each proving the invariant with the fictitious-stage harness +
golden-parity + characterization gates (a "remove/rename a stage" change cannot be
dogfooded through the pipeline itself — the running pipeline is the artifact being
modified — so confidence is substituted by these deterministic gates):

- **A** (#1278) — this ADR + amendments + agnostic base-prompt scrub.
- **E** (#1279) — lint-contract scope derived from manifest contract-participation (§5 rule).
- **B** (#1280) — verdict push channel (§3).
- **C** (#1281) — cycle capability flags (§4).
- **D** (#1282) — retire `_ZBUILD_CANONICAL_STAGES`; fail-closed preflights (§5); strips the
  per-repo overlay's roster enumeration as the prompt-side tombstone of the retired set.
- **F** (#1283) — generic post-stage hook + derived fallback.
- **G** (#1284, optional) — multi-condition `exit_when`.
- **H** (#1285, optional) — generalize `fanout` → data-driven `map`.

## References

- [ADR-013](ADR-013-canonical-stage-list.md) — canonical-stage list. **Amended (demoted).**
- [ADR-019](ADR-019-review-fail-closed-on-test-failure.md) — fail-closed. **Amended (generalized).**
- [ADR-020](ADR-020-inter-stage-data-contract.md) — inter-stage data contract (the real
  invariant canonical-order proxied).
- [ADR-032](ADR-032-per-repo-prompt-overrides.md) — per-repo prompt-override mechanism.
  **Preserved.**
- [ADR-040](ADR-040-composable-gate-lens-taxonomy.md) — marker-driven discovery.
  **Amended (extended).**
- [ADR-042](ADR-042-stage-portability.md) — role-then-id resolution. **Completed.**
