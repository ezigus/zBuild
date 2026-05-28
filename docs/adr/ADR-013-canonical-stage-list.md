# ADR-013: Canonical Stage List

**Status:** Accepted
**Date:** 2026-05-27

## Context

The pipeline stage sequence `intake → plan → design → build → test → review →
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

The canonical pipeline sequence is **exactly 11 stages in this order**:

```
intake → plan → design → build → test → review →
compound_quality → pr → deploy → validate → monitor
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
| review | agent | T2 | init, run, finalize | review.json | true |
| compound_quality | orchestrator | T3 | init, run, finalize, cleanup | compound-quality-result.json | true |
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
- `compound_quality` is `orchestrator`: it drives multiple `agent` sub-plugins
  through a multi-phase loop.  It is the only stage that uses the orchestrator
  `run` hook signature (upstream artifacts in, downstream artifacts + verdict
  out per ADR-001 §"Required interfaces per kind").

### Tier assignment rationale

- T0 (`test`, `pr`, `deploy`, `validate`): no model call, ever.  Using T0 here
  documents an architectural invariant; any attempt to inject model calls into
  these stages is a bug.
- T1 (`intake`, `monitor`): light summarization; micro-LLM is sufficient.
  `intake` declares T1 as forward-compatibility for a planned planning prompt;
  the Phase 0.5 stub makes no LLM call yet, but the manifest already declares
  `requires.core: [redaction]` to enforce the chokepoint contract.
- T2 (`plan`, `build`, `review`): standard reasoning; balanced cost/quality.
- T3 (`design`, `compound_quality`): architecture-level decisions and
  multi-lens audit require the highest available reasoning tier.

### compound_quality sub-phases

`compound_quality` is the only stage with internal phases.  Its orchestrator
plugin executes them in this order:

```
preflight → audit_plan → cycle → backtrack
```

| Sub-phase | Purpose |
|---|---|
| `preflight` | Non-cyclic fast-fail checks (bash-compat, coverage floor, untested functions). Failure aborts immediately without entering the cycle loop. |
| `audit_plan` | Selects which audit lenses run and at what intensity, based on quality-score history from learning memory (ADR-011). |
| `cycle` | Iterative audit loop.  Dispatches selected lens plugins (security, logic, performance, architecture, correctness, edge-case, pessimist).  Detects plateau and divergence. |
| `backtrack` | If unresolved architecture-class findings remain after the cycle cap, emits `recovery.suggestion` targeting the design stage.  Non-blocking: backtrack exhaustion degrades to "continue with warning" rather than halting. |

The four sub-phase ids (`preflight`, `audit_plan`, `cycle`, `backtrack`) MUST
be used in event payloads and plugin manifests when referencing compound_quality
internals.

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
| compound_quality | Phase 0.5 | Shipped — security-lens only; full 7-lens suite deferred to Phase 1 |
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
- The compound_quality sub-phase vocabulary is stable; event payloads and
  plugin manifests can reference it without ambiguity.

**Bad:**

- Adding a new stage or changing a tier assignment requires an ADR-013
  revision.  The friction is intentional; it keeps the canonical list stable.
- Existing templates and plugin manifests that use ad-hoc stage references
  must be updated to use the ids in this table.

**Open questions deferred to Phase 1:**

- Whether stages beyond `intake` may run with intra-stage parallelism by
  default (currently per-template opt-in via ADR-009 strategy).
- The exact convergence criteria for the compound_quality cycle sub-phase
  (plateau N, divergence threshold).  Tracked in #12 and #13–#16.
- UCB1 bandit selection within compound_quality lens scheduling (ADR-003 §UCB1
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

## References

- [ARCHITECTURE.md §3](../ARCHITECTURE.md#3-data-flow-a-zbuild-pipeline-start-traversal) — data flow traversal
- [KEEPERS.md §A](../KEEPERS.md#section-a--pipeline--stage-composition-verified) — stage dispatch and compound_quality 4-phase split
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
