# ADR-013: Canonical Stage List

**Status:** Accepted
**Date:** 2026-05-27

## Context

The pipeline stage sequence `intake → plan → design → build → test → test_assessment → review →
compound_quality → pr → deploy → validate → monitor` is referenced throughout
the codebase and in ARCHITECTURE.md §3, but no ADR has formally defined it.
The informal list has two problems:

1. Plugin developers have no authoritative source for stage ids, kinds, tiers,
   required hooks, or expected artifacts — they reverse-engineer them from
   `legacy/scripts/lib/pipeline-stages-*.sh`.
2. The template runner has no canonical vocabulary to validate stage ids against
   at template-load time, so a typo in a template silently produces a no-op
   instead of an error.

This ADR closes both gaps.  It is intentionally scoped to Phase 0.5: it defines
the taxonomy so the Wave B plugins (plan, build, test, review, pr) can write
conformant manifests before implementation begins.  Unimplemented stages are
skipped by omission from the active template; their presence in this ADR does
not require them to be implemented.

## Decision

### Stage sequence

The canonical pipeline sequence is **exactly 15 stages in this order**:

```
intake → plan → design → build → test → test_assessment →
cq-preflight → cq-audit-plan → cq-cycle → cq-backtrack →
review → pr → deploy → validate → monitor
```

The runner validates every stage id in a template against this list at
template-load time.  Unknown ids are rejected with a structured error.
Templates may omit stages (subtractive composition); they may **not** add
stages not in this list without a new ADR-013 revision.

The sequence is strictly sequential by default.  Intra-stage parallelism
(multiple plugins serving one stage via fanout strategy per ADR-009) is
governed by the template, not by this ADR.

### Stage taxonomy

Each stage is defined by:

| Field | Meaning |
|---|---|
| `id` | Stable snake_case identifier.  Referenced in templates and manifests. |
| `kind` | Plugin kind required for this stage (`agent`, `tool`, `orchestrator`, `daemon`). |
| `tier` | Default model-routing tier (ADR-003).  T0 = no LLM; T1–T4 = ascending capability/cost. |
| `lifecycle_hooks` | Hooks the engine invokes on the stage's plugin.  Per ADR-001, the only kind-required entry point is `run` (agent/tool/orchestrator) or `tick` (daemon); `init`, `finalize`, and `cleanup` are optional but listed here when the stage's plugin is expected to implement them. |
| `expected_artifact` | Filename the stage MUST produce under `ZBUILD_ARTIFACT_DIR` (`state/artifacts/`).  `intake` is the single exception: it writes `state/scope-manifest.md` directly (outside `artifacts/`) because every downstream redaction call reads it from that stable path. |
| `blocking` | Whether stage failure halts the pipeline (`true`) or degrades gracefully (`false`). |

### Canonical stage definitions

| id | kind | tier | lifecycle_hooks | expected_artifact | blocking |
|---|---|---|---|---|---|
| intake | agent | T1 | init, run, finalize | scope-manifest.md† | true |
| plan | agent | T2 | init, run, finalize | plan.json | true |
| design | agent | T3 | init, run, finalize | design.md | true |
| build | agent | T2 | init, run, finalize | build-summary.json | true |
| test | tool | T0 | init, run, finalize | test-results.json | true |
| test_assessment | agent | T2 | init, run, finalize, cleanup | test-assessment.json | true |
| cq-preflight | agent | T1 | init, run, finalize | cq-preflight-result.json | true |
| cq-audit-plan | agent | T2 | init, run, finalize | audit-plan.json | true |
| cq-cycle | agent | T3 | init, run, finalize, cleanup | quality-feedback.md | true |
| cq-backtrack | agent | T1 | init, run, finalize | recovery-suggestion.json | false |
| review | agent | T2 | init, run, finalize | review.json | true |
| pr | tool | T0 | init, run, finalize | pr-url.txt | true |
| deploy | tool | T0 | init, run, finalize | deploy.log | true |
| validate | tool | T0 | init, run, finalize | validate-result.json | true |
| monitor | daemon | T1 | init, tick, finalize, cleanup | monitor-report.md | false |

† `intake`'s `scope-manifest.md` is written to `state/scope-manifest.md` directly, not under `state/artifacts/`, because every downstream redaction call must find it at this stable path.

### Kind assignment rationale

- `test`, `pr`, `deploy`, and `validate` are `tool`: they invoke existing
  processes with no LLM reasoning, so they never declare
  `requires.core: [redaction]`.  This keeps the redaction chokepoint (ADR-004)
  honest.
- `monitor` is `daemon`: it runs a poll loop that outlives the pipeline run;
  the one-shot `run` contract of `tool`/`agent` does not fit.  Per ADR-001,
  `daemon` plugins use `tick` (not `run`) as their periodic entry point.
- `cq-preflight`, `cq-audit-plan`, `cq-cycle`, and `cq-backtrack` replace the
  former `compound_quality` orchestrator.  Each is an independent `agent` leaf
  stage with its own manifest, plugin, and artifact contract.  The four stages
  execute sequentially; `cq-preflight` failure is fail-fast (skips the
  remaining three).  `cq-cycle` is T3 because it drives multi-lens audit
  reasoning; the others are T1/T2.

### Tier assignment rationale

- T0 (`test`, `pr`, `deploy`, `validate`): no model call, ever.  Using T0 here
  documents an architectural invariant; any attempt to inject model calls into
  these stages is a bug.
- T1 (`intake`, `monitor`): light summarization; micro-LLM is sufficient.
  `intake` declares T1 as forward-compatibility for a planned planning prompt;
  the Phase 0.5 stub makes no LLM call yet, but the manifest already declares
  `requires.core: [redaction]` to enforce the chokepoint contract.
- T2 (`plan`, `build`, `review`, `cq-audit-plan`): standard reasoning; balanced cost/quality.
- T3 (`design`, `cq-cycle`): architecture-level decisions and multi-lens audit
  require the highest available reasoning tier.

### CQ stage responsibilities

The former `compound_quality` orchestrator is replaced by four independent leaf
stages executed in sequence within the `review_cycle` flow:

| Stage | Purpose |
|---|---|
| `cq-preflight` | Non-cyclic fast-fail checks (bash-compat, coverage floor, untested functions). Failure aborts immediately; the remaining three CQ stages are skipped. |
| `cq-audit-plan` | Selects which audit lenses run and at what intensity, based on quality-score history from learning memory (ADR-011). Emits `audit-plan.json` consumed by `cq-cycle`. |
| `cq-cycle` | Iterative audit loop. Dispatches selected lens plugins (security, logic, performance, architecture, correctness, edge-case, pessimist). Detects plateau and divergence. Emits `quality-feedback.md` and `review.findings.json`. |
| `cq-backtrack` | If unresolved architecture-class findings remain after the cycle cap, emits `recovery.suggestion` targeting the design stage. Non-blocking: backtrack exhaustion degrades to "continue with warning" rather than halting. |

### Artifact paths and the fail-closed rule

All `expected_artifact` values in the table are filenames under `ZBUILD_ARTIFACT_DIR`
(`state/artifacts/`).  `intake` is the single exception: it writes
`state/scope-manifest.md` directly (the `†` in the table) because every
downstream redaction call reads it from that stable path outside `artifacts/`.

The fail-closed scanner rule (ARCHITECTURE.md §2, Keepers §C.4) applies to
every `expected_artifact` in the table above:

> If a stage plugin exits 0 but its declared output path does not exist or is
> empty, the engine emits a synthetic `stage.fail` with
> `reason: "missing_artifact"` and routes to `kind: recovery` plugins.

### Stage skip conditions

A stage may be skipped when:

1. `stage_status == "complete"` and `resume_mode == true` — already completed
   on a previous attempt of this run (ADR-006 resume contract).
2. The template lists the stage in `disabled_stages`.
3. A stage-specific guard fires (e.g. `validate` is skipped when `deploy` was
   skipped; `monitor` is skipped when `ZBUILD_MONITOR_ENABLED` is unset).

Skipped stages emit `stage.skip` on the event bus with a `reason` field.

> **Cycle interaction (ADR-021):** `--from-stage <s>` is refused if
> `<s>` is inside or after a `cycles[].stages[]` entry. Resume into a
> mid-cycle iteration uses the cycle orchestrator's own iter-N+1
> dispatch (ADR-021 §Resume contract), not `--from-stage`.

### Template integration

Templates define a subset of stages via their `stages:` array.  The runner
enforces two rules at template-load time:

1. Every stage id in the template must appear in the canonical sequence above.
   Unknown ids → structured error (not a warning).
2. If stages are listed in the template, they must appear in the same relative
   order as the canonical sequence.  Reordering is not permitted without a
   new ADR-013 revision.

Minimal template example (security audit):

```yaml
id: security-audit
disabled_stages: [deploy, validate, monitor]
stages:
  - id: intake
    roles: [intake]
  - id: review
    roles: [security-auditor]
  - id: pr
    roles: [output]
```

### Phase gating

Stages are grouped into delivery phases.  A stage is skipped by omission from
the active template until its implementation phase ships:

| Stage | Required from phase | Status |
|---|---|---|
| intake | Phase 0.5 | Shipped — plugin + tests + parity coverage |
| cq-preflight, cq-audit-plan, cq-cycle, cq-backtrack | Phase 1 | Shipped — 4 leaf stages replacing compound_quality (issue #755) |
| plan, design, build, test, review | Phase 1 | Planned — not yet shipped |
| pr | Phase 1 (optional) | Planned — not yet shipped |
| deploy, validate, monitor | Phase 3 | Planned — not yet shipped |

## Consequences

**Good:**

- Plugin authors have a single authoritative source for stage vocabulary.
- The runner can validate template stage ids at load time and fail loudly on
  typos.
- Tier assignments document architectural invariants (T0 = never LLM) that
  previously lived only in convention.
- The CQ stage vocabulary (cq-preflight, cq-audit-plan, cq-cycle, cq-backtrack)
  is stable; event payloads and plugin manifests can reference it without ambiguity.

**Bad:**

- Adding a new stage or changing a tier assignment requires an ADR-013
  revision.  The friction is intentional; it keeps the canonical list stable.
- Existing templates and plugin manifests that use ad-hoc stage references
  must be updated to use the ids in this table.

**Open questions deferred to Phase 1:**

- Whether stages beyond `intake` may run with intra-stage parallelism by
  default (currently per-template opt-in via ADR-009 strategy).
- The exact convergence criteria for the cq-cycle plateau detection
  (plateau N, divergence threshold).  Tracked in #12 and #13–#16.
- UCB1 bandit selection within cq-cycle lens scheduling (ADR-003 §UCB1
  deferred to #29).

## Implementation Notes (Phase 0.5 — issue #292)

| Item | Status | Notes |
|---|---|---|
| Canonical stage list defined | Implemented | This ADR |
| ARCHITECTURE.md §3 cross-link | Implemented | See §3 data-flow diagram |
| Template runner stage-id validation | Deferred | Phase 1 — tracked in #12 |
| plan/design/build/test/pr plugins | Deferred | Phase 1 wave B |
| deploy/validate/monitor plugins | Deferred | Phase 3 |
| `config/artifact-schema.json` | Deferred | Phase 1 — schemas for structured artifacts |

### Canonical vs. secondary artifacts (issue #361)

A stage plugin MAY write additional artifacts beyond the single
`expected_artifact` named in the canonical table above.  When it does, the
following rules apply:

1. The filename in the `expected_artifact` column is the **canonical artifact**.
   It is the value that MUST appear in the plugin manifest's
   `provides.artifact_type` field, and it is the artifact the fail-closed
   contract checker (ARCHITECTURE.md §2, ADR-001 §"Fail-closed scanner
   contract", `core/pipeline/contracts.sh::_check_artifact_contract`)
   verifies is **present and non-empty** on stage exit.  Downstream stages
   reference this filename when wiring inputs.
2. Any other files the plugin writes are **secondary artifacts**.  They MAY
   be listed in the manifest's `outputs[]` array alongside the canonical
   artifact, but they MUST NOT appear in `provides.artifact_type`, and no
   downstream stage wiring is allowed to depend on them — they remain
   observability/debugging aids from the pipeline-contract perspective.
   Note: any path listed in `outputs[]` is still enforced for **existence**
   on a successful run by `scan_plugin_outputs`
   (`core/plugin-registry/registry.sh`, issue #288), so a plugin that
   declares a secondary output must actually produce it on the success path.
   Plugins that genuinely cannot guarantee a secondary file on every success
   should leave it out of `outputs[]`.
3. The canonical artifact MUST be the first entry in `outputs[]` because
   the two artifact layers split responsibilities:
   - `_check_artifact_contract` (contracts.sh) reads only the **first**
     `outputs[].path` and uses it as the non-empty / `provides.artifact_type`
     verification target.  Putting the canonical entry first is what makes
     that check land on the right file.
   - `scan_plugin_outputs` (registry.sh) iterates **every** `outputs[].path`
     and emits `plugin.artifact.missing` for any that don't exist after a
     0-exit run.  Ordering doesn't matter for this scan, but it does matter
     for the first-entry contract check above.

**Worked example — `pr` stage:**

- Canonical: `pr-url.txt` (one line, the PR URL — what downstream cares about).
- Secondary: `pr-result.json` (richer status payload: `status`, `branch`,
  `draft`, `pr_number`, error detail when blocked).
- Both files are written on a successful PR open; `pr-result.json` is also
  written on the `verdict=block` and `main-branch-guard` refusal paths so
  operators have a structured failure record.  The first-entry contract
  check (`_check_artifact_contract`) verifies `pr-url.txt` is present and
  non-empty as the canonical `provides.artifact_type` target; the secondary
  `pr-result.json` is enforced for existence by `scan_plugin_outputs` on
  the success path because it is declared in `outputs[]`, but downstream
  stages MUST NOT wire inputs from it.

This convention generalizes: any future stage that benefits from a structured
side-channel (e.g., `test` writing both a human summary and JUnit XML) follows
the same canonical-plus-secondary pattern, with `provides.artifact_type` always
pointing at the canonical entry from the table above.

## Amendment — Cycle composition (issue #512, ADR-021)

ADR-021 introduces an overlay `cycles:` block. Cycle membership is purely
an annotation on stages already listed in canonical `stages:`. Invariants
preserved by the parser+validator:

1. Every stage id referenced by `cycles:` MUST already appear in `stages:`.
2. A cycle's `stages: [...]` MUST be a **contiguous subsequence** of the
   canonical `stages:` order — no skipping, no reordering.
3. Cycles MUST NOT overlap (each stage belongs to at most one cycle).
4. `until.stage` MUST be in `cycle.stages[]`.

The runner walks `_TPL_STAGES[]` in canonical order as before. When a
stage is the FIRST stage of a declared cycle, the runner emits a
`cycle:<id>` dispatch unit covering the whole cycle; the remaining cycle
stages are absorbed under that unit. All other stages become `stage:<id>`
dispatch units. With no `cycles:` block, every unit is `stage:<id>` and
linear dispatch is byte-identical to today (regression-locked in
`tests/unit/core-pipeline-template-cycles-test.sh`).

## References

- [ARCHITECTURE.md §3](../ARCHITECTURE.md#3-data-flow-a-zbuild-pipeline-start-traversal) — data flow traversal
- [KEEPERS.md §A](../KEEPERS.md#section-a--pipeline--stage-composition-verified) — stage dispatch and CQ 4-plugin migration
- [ARCHITECTURE.md §2](../ARCHITECTURE.md#2-plugin-contract) — plugin contract, fail-closed scanner ("absent evidence IS blocking evidence")
- [ADR-001 §Fail-closed scanner contract](ADR-001-plugin-contract.md#fail-closed-scanner-contract) — synthetic blocking finding when declared artifact is missing after exit 0
- [ADR-003](ADR-003-models-as-data.md) — tier ordinals T0–T4
- [ADR-004](ADR-004-redaction-chokepoint.md) — redaction chokepoint, scope-manifest.md
- [ADR-006](ADR-006-resume-contract.md) — resume semantics, stage status persistence
- [ADR-009](ADR-009-platform-aware-modularity.md) — fanout/composite/sequential strategies
- [ADR-011](ADR-011-pluggable-backends.md) — learning memory backend for quality scores
- [ADR-012](ADR-012-test-tiering-and-ci-gating.md) — test tier definitions (unit/integration/e2e)
- `legacy/scripts/sw-pipeline-resume-test.sh` — canonical stage list in legacy (12 stages including `merge`; `merge` is implicit in the `pr` stage in this ADR)
- `legacy/scripts/lib/pipeline-stages-*.sh` — stage implementations (reference only)

## Amendment 2026-05-31 (#572) — `test_assessment` inserted between `test` and `review`

Per ADR-022, the canonical stage sequence is extended from 11 to 12 stages by inserting `test_assessment` (Pattern 1 agent stage, tier T2) between `test` and `review`. The new stage is `blocking: true`. Templates that don't need LLM-interpreted test verdicts may continue to omit it (subtractive composition rule unchanged). Existing templates that omit `test_assessment` keep ADR-019's fallback semantics where review reads `test.verdict` directly.

References: ADR-018 (Pattern 1), ADR-019 §7 (verdict precedence), ADR-020 §LLM-interpreted verdict stages, ADR-021 §test_assessment until: source, ADR-022 (full record), #567 (impl), #572 (this amendment).

## Amendment 2026-06-02 (#447 / ADR-016 prerequisite) — Taxonomy-only scope clarification

This ADR is the **taxonomy** for canonical stage IDs and their per-stage attributes (kind, tier, lifecycle hooks, expected artifact, blocking). It defines *what a stage ID means*. It does **not** define *what should be present in any particular pipeline*.

The "should" question is governed elsewhere:

- **Structural realization** (cycle entries, `stage_definitions:` hoisting, execution-order tokens that aren't canonical stage IDs themselves) is owned by ADR-021 v2. Templates declare order via `stages: [...]` which may contain composite cycle entries; each cycle entry expands to canonical IDs via its own `stages:` member list (defined in the cycle entry under `stage_definitions:`), and `stage_definitions:` carries the per-stage attributes for those member stages. A template's *flattened, resolved* stage set — not its raw `stages:` list — is what gets compared to this ADR's taxonomy.

- **Per-repository template resolution and base-template diff** are owned by ADR-016 (filed as a follow-up). When a per-repo `.zbuild/templates/<id>.yaml` resolves via `extends:`, the engine computes a diff between the resolved override and its declared base template, NOT against the full list in this ADR. The diff fires `pipeline.template.diff_from_base` for operator visibility but never blocks execution.

Consequently, the "subtractive composition" rule in §"Stage sequence" remains true (templates may omit stages and the runner validates only that present IDs are members of the taxonomy), but the rule about *which* omissions matter to a particular pipeline is template-family-specific, not engine-hardcoded. Future shipped templates (e.g., a hypothetical `issue-creation` family) define their own expected stage set by being what they are; the engine knows nothing about that beyond ID validity.

References: ADR-016 (per-repository template resolution), ADR-021 v2 (cycle/composite structural mechanism), #447 (implementation umbrella), #652/#653/#654/#655/#656 (sub-issues for ADR-016 + impl).

## Amendment 2026-06-05 (#705 / ADR-027) — Cycles are stages-with-flows

ADR-027 (Wave 17-A) codifies the recursive flow template format: a cycle is a stage that happens to contain its own mini-flow, declared by `type: cycle` on a top-level stage section with its own `flow:` member list. The runner walks any `flow:` the same way at any depth. This amendment clarifies how this ADR's taxonomy composes with that recursive shape; it does NOT change the taxonomy itself.

**Taxonomy scope unchanged.** The canonical stage list in §"Stage sequence" and the per-stage attribute table in §"Canonical stage definitions" remain the authoritative source for **leaf** stage IDs (`intake`, `plan`, `design`, `build`, `test`, `test_assessment`, `cq-preflight`, `cq-audit-plan`, `cq-cycle`, `cq-backtrack`, `review`, `pr`, `deploy`, `validate`, `monitor`) and their `kind`, `tier`, `lifecycle_hooks`, `expected_artifact`, and `blocking` attrs. Adding a new leaf stage ID or changing a leaf's attrs still requires an ADR-013 revision.

**Cycle stage IDs are template-defined.** Cycle stages (e.g., `build_test_cycle`, `review_cycle`) are NOT members of the canonical leaf set. Each template defines its own cycle stage IDs as sibling top-level sections, named to describe what the cycle does. Cycle stage IDs are scoped to the template that declares them; two templates may use different cycle IDs without conflict, and a cycle ID in one template MUST NOT collide with any canonical leaf ID from this ADR.

**ID validation applies to every `flow:` member at every depth.** The runner walks the resolved flow recursively (post-`extends`-merge per ADR-027 §"Loader contract"). Every member of any `flow:` — whether that `flow:` is the top-level one or nested inside a cycle stage's section, at any depth — must resolve at template-load time to exactly one of:

1. A **canonical leaf stage ID** from this ADR's §"Canonical stage definitions" table (these are governed by this ADR — kind/tier/lifecycle_hooks/expected_artifact/blocking), OR
2. A **sibling cycle stage ID** defined in the same template (a top-level section with `type: cycle`; governed by ADR-027 and ADR-021 v2, not this ADR).

An ID that resolves to neither is rejected at template-load time with a structured error, parity with the existing canonical-ID validation. After classification, the runner recurses into any cycle-classified member's own `flow:`, applying the same rule. The taxonomy-driven leaf attrs in §"Canonical stage definitions" are enforced only at the **leaf** classification — cycle stages have their own attr contract per ADR-027 §"Decision" (see the "Cycle stage attrs are not taxonomy-governed" paragraph below).

The "subtractive composition" rule (templates MAY omit leaf stages) and the "canonical order" rule (when leaf stages appear, they must appear in canonical relative order) both still hold at every depth: the leaf members of any one `flow:` — top-level OR inside a cycle — are a contiguous subsequence of the canonical order, just as the top-level `stages:` list was under the pre-ADR-027 shape. Sibling cycle stage IDs interleaved into a `flow:` do not participate in the leaf canonical-order check.

**Per-stage attrs follow the section, not the position.** Under ADR-027 every stage's attrs (gate, roles, io, router, etc.) live in its top-level section keyed by stage ID. A leaf referenced from inside a cycle's `flow:` has the same section as a leaf referenced from the top-level `flow:` — there is no inline-vs-hoisted split. This kills the prior friction where cycle members needed a parallel `stage_definitions:` map; the taxonomy attrs from this ADR apply to a leaf stage's section once, regardless of where the ID is referenced.

**Cycle stage attrs are not taxonomy-governed.** Cycle stages carry `type: cycle`, their own `flow:`, `exit_when:`, optional `abort_when:`, `max_iterations:`, `on_max:`, and `feedback:`. These attrs are governed by ADR-027 §"Decision" and ADR-021 v2's cycle execution model — NOT by this ADR's per-stage attribute table. The taxonomy in §"Canonical stage definitions" is intentionally silent on cycle stages because their identity is template-defined and their per-stage shape comes from the cycle contract, not the leaf contract.

References: ADR-027 §"Decision" and §"Loader contract" (Wave 17-A), Wave 17-B (#703, template loader + validator + back-compat shim), Wave 17-C (#704, `config/templates/standard.yaml` migration), ADR-021 v2 (cycle execution model), the 2026-06-02 amendment above (taxonomy-only scope clarification — extended here from "flattened, resolved stage set" to "flat resolved flow at every depth").

## Amendment 2026-06-13 (#755) — compound_quality replaced by 4 CQ leaf stages

`compound_quality` (orchestrator, T3) is removed from the canonical taxonomy.
It is replaced by four independent `agent` leaf stages inserted between
`test_assessment` and `review`:

| id | kind | tier | expected_artifact | blocking |
|---|---|---|---|---|
| cq-preflight | agent | T1 | cq-preflight-result.json | true |
| cq-audit-plan | agent | T2 | audit-plan.json | true |
| cq-cycle | agent | T3 | quality-feedback.md | true |
| cq-backtrack | agent | T1 | cq-backtrack-result.json | false |

The canonical stage count grows from 12 to 15. The stage sequence is now:
`intake → plan → design → build → test → test_assessment → cq-preflight →
cq-audit-plan → cq-cycle → cq-backtrack → review → pr → deploy → validate → monitor`

Tombstone: `legacy/migrated/A2-compound-quality.md`. Implementation: issue #755.
