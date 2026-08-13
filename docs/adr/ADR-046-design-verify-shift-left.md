# ADR-046 — Design-verify shift-left: a mechanical structural gate PRE-build

**Status:** Accepted (2026-07-03, issue #1218, EPIC #1216)

**Amended:** 2026-08-12 (#1768, ADR-055 §1) — the `source: artifacts` prescription for `prior_gate_feedback` is retired. The cross-cycle feedback edge is now an ordinary name-matched input, made legal by ADR-055 §1.3 (a declared `route_back` edge legalises a backwards data edge) rather than by an untyped read of the shared artifact directory. The *reasoning* below stands unchanged and was correct — this edge genuinely is not `cycle_feedback`; only the mechanism changes. ADR-055 did not enumerate `source: artifacts` at all, so this ADR was its sole specification and the two documents disagreed until now.

**Related:**
- amends: ADR-036 (acceptance-contract teeth) — Level-1 SPEC-tag-presence shifts LEFT to a PRE-build design-gate; the post-build acceptance-gate keeps Level-2 negative-control (tautology) + Level-3 reachability, which cannot shift left.
- extends: ADR-037 (objective gates vs semantic judgment) / ADR-040 (composable gate/lens taxonomy) — design-gate is a new first-class `kind: tool`, `convergence: gate` T0 stage; the semantic sibling stays advisory.
- amends: ADR-013 (canonical-stage list) — `design-gate` is added between `design` and `impact`.
- peer: ADR-042 (stage portability) — design-gate is repo-agnostic: generic grep over the contract, no plugin/lang/path assumptions.
- reserved: ADR-045 is reserved for #1217's bounded typed backward-route (the EPIC #1216 keystone); this ADR is ADR-046.

## Context

`standard.yaml` wraps `design` in a `design_impact_cycle` (design → impact, exit_when
`impact.verdict == complete`) so the design stage gets an independent verifier that loops
back to it. `simple.yaml` had no such loop: the `design` stage ran once, and any
design/contract defect (unclassified SPEC, missing WIRING, an untagged or missing testfile,
an empty scope) was only discovered deep in the build cycle — or not at all — as an opaque
`member_terminal_failure`. This is the recurring "self-certify → discover late → dead-end"
failure the pipeline-correctness EPIC (#1216) targets.

ADR-036 gave the acceptance-gate teeth, but that gate runs POST-build: its Level-2
(negative-control / tautology) and Level-3 (reachability) checks genuinely need a built
assertion and a baseline-vs-HEAD run, so they cannot move earlier. The Level-1
SPEC-tag-presence check, however, is pure grep over `design.md` + the red-first stubs the
design stage already writes — it needs no build and no baseline. It belongs where the
contract is authored.

## Decision

Add a **`design_verify_cycle`** to `simple.yaml` (modelled on `standard.yaml`'s
`design_impact_cycle`) with two members, `design → design-gate`, and a new mechanical gate
plugin. Convergence is `exit_when design-gate.verdict == pass`, `max_iterations: 3`,
`on_max: continue` (ADR-019 fall-through). Feedback loops the gate's findings back into
`design.prior_impact_feedback` (reused input) plus a `design → design.prior_design`
self-edge.

### 1. `design-gate` — a new T0 tool plugin (`plugins/tool/design-gate`)

- `kind: tool`, `convergence: gate`, `provides.role: design_gate`, `tier_default: T0`.
- **No LLM, no baseline** (ADR-037 §3 invariant). Pure grep over `design.md` + the stubs.
- Runs six structural checks and **reports ALL violations in ONE pass** (no whack-a-mole):
  - **C1 SCOPE** — `design.md` carries a non-empty ` ```scope ` block.
  - **C2 ACCEPTANCE** — the ` ```acceptance ` block is present + parseable.
  - **C3 CLASSIFIED** — every `SPEC-n` carries a `[change]` or `[guard]` classifier.
  - **C4 CHANGE-HAS-TESTFILE** — if ≥1 `[change]` SPEC, `TESTFILES` is non-empty and each
    declared testfile exists on disk.
  - **C5 WIRING** — a `WIRING:` section is present (`none` is a valid exemption); each
    concrete path exists on disk.
  - **C6 LEVEL-1 TAG-PRESENCE** — every `SPEC-n` has a `[SPEC-n]` tag in a declared testfile
    (reuses `scripts/lib/acceptance-coverage.sh`, shifted left from the acceptance-gate).
- Verdict-in-artifact (ADR-040): writes `{verdict, violations[]}` to
  `design-gate-result.json` and ALWAYS returns rc=0 — the cycle's `exit_when` reads
  `.verdict`. Writes `design-gate-feedback.md` ONLY on fail.
- design-gate is BOTH a cycle member AND `convergence: gate`, so the typed-aggregator
  preflight (contract-validator rule A) is satisfied by binding `exit_when` directly to it —
  a **single** gate, no separate aggregator (contrast `build_test_cycle`, whose
  `gate-aggregator` rolls up many gates).

### 2. Companion change: the design stub-writer embeds `[SPEC-n]` tags

`design/plugin.sh` writes a red-first stub for each declared `TESTFILE` that does not yet
exist. Those stubs previously carried no SPEC tag, so C6 would never pass and the cycle
would loop forever. The stub body now embeds the `[SPEC-n]` tags for the **change**-classified
SPECs (the block lists `TESTFILES` globally, so every change-SPEC tag goes into every new
stub — any-declared-testfile-contains-tag). Guard SPECs are expected to reference
pre-existing tagged tests.

### 3. The semantic sibling stays advisory (reuse `impact`)

The "are these SPECs genuinely new + separable?" judgment is the reused `impact` T2 agent,
placed as a **lone top-level stage AFTER `design_verify_cycle` and BEFORE `build_test_cycle`**
— advisory BY PLACEMENT (ADR-040): no `exit_when`, drives no convergence, never blocks, and
runs ONCE rather than per design iteration. `impact`'s manifest is left **marker-less** (no
`convergence:`) on purpose: `standard.yaml`'s `design_impact_cycle` binds `impact` via
`exit_when`, and the typed-aggregator preflight only checks marker-bearing targets — a
marker on `impact` would break `standard.yaml`.

### Flow (simple.yaml)

`intake → plan → design_verify_cycle{design, design-gate} → impact → build_test_cycle{…} →
review_lenses → review-aggregator → pr`.

## Consequences

- `simple.yaml`'s `_TPL_STAGES` grows 16 → 18 (adds `design-gate`, `impact`); dispatch units
  7 → 8. This is a template shape change: the `_TPL_STAGES[N]`-indexed order tests
  (`tests/unit/template-simple-yaml-test.sh`) are updated in the same diff (shape-floor
  contract). `design-gate` is added to the canonical stage list in `core/pipeline/template.sh`.
- `design_gate.pass` / `design_gate.fail` are registered in `config/event-schema.json`.
- `standard.yaml` and the production default templates are untouched: `impact` stays
  marker-less; only `simple.yaml` gains the cycle.
- Belt-and-suspenders: the post-build acceptance-gate's Level-1 check still runs and now
  trivially passes for a design that already cleared design-gate.

## Implementation Notes (issue #1218)

- Plugin: `plugins/tool/design-gate/{manifest.yaml,plugin.sh}` (hook prefix `design_gate_`,
  sources `acceptance-block.sh` + `acceptance-coverage.sh`). `_dg_scope_nonempty` implements
  C1; C2–C6 reuse the existing block parsers. Always rc=0; verdict-in-artifact.
- Helpers: `acceptance_spec_classifier` / `acceptance_spec_is_change` added to
  `scripts/lib/acceptance-block.sh` (mirror the existing `acceptance_spec_is_guard` parse).
- Stub-writer: `plugins/agent/design/plugin.sh` embeds `[SPEC-n]` tags for change SPECs in
  each new red-first stub so C6 is satisfiable.
- Template: `design_verify_cycle` + `design-gate`/`impact` sections in
  `config/templates/simple.yaml`; `design-gate` added to the canonical stage list in
  `core/pipeline/template.sh` (between `design` and `impact`).
- Events: `design_gate.pass` / `design_gate.fail` registered in `config/event-schema.json`.
- Tests: `tests/unit/design-gate-test.sh` (C1–C6 red-first + report-all + rc=0 + classifier);
  `tests/unit/template-simple-yaml-test.sh` re-pinned to the 18-stage / 8-dispatch-unit shape.

## Amendment (#1219, 2026-07-04) — design_verify_cycle is the route_back target for design-rooted acceptance failures

ADR-046 gave design an independent PRE-build verifier that loops back TO it. #1219 (the final piece of
EPIC #1216) makes `design_verify_cycle` the **rewind target** for a design-rooted defect discovered
DEEPER in the pipeline: a tautological `[change]` SPEC that the post-build acceptance-gate (Level-2
negctl) catches — which, unlike the structural checks, CANNOT shift left (it needs a built assertion +
a baseline-vs-HEAD run). `simple.yaml`'s `build_test_cycle` declares
`route_back: {to: design_verify_cycle, when: {stage: gate-aggregator, field: verdict, op: eq,
value: route_design}, max: 1}` (ADR-045). On `route_design` the runner rewinds the dispatch index to
`design_verify_cycle` and replays forward (design_verify_cycle → impact → build_test_cycle), so design
re-authors the SPEC then the design-gate re-verifies it — closing the loop where the contract was
authored, not where the defect surfaced.

Feedback path: the gate-aggregator writes a focused `design-feedback.md`; the design manifest gains a
new input `prior_gate_feedback` (~~`source: artifacts`, `path: ${artifact_dir}/design-feedback.md`~~,
`required: false` — NOT `cycle_feedback`, which is intra-`design_verify_cycle`; this arrives from the
OTHER cycle across the rewind).

> **Amended 2026-08-12 (#1768).** The input is now declared by artifact name alone —
> `- id: design_feedback` with `required: false` — and the engine resolves it to the
> gate-aggregator, the single stage in the flow that produces it (ADR-055 §1, §5). The
> backwards direction is legal because the `route_back` edge declared immediately above
> is exactly the evidence the ordering check consults (ADR-055 §1.3). The struck-out
> `source: artifacts` was an untyped escape hatch: no producer, no ordering, and — because
> the runtime validator skipped optional inputs entirely — no validation of any kind. `design/plugin.sh` splices it into the prompt keyed on file PRESENCE
(absent on the first pass → no-op). Bounded by ADR-045's per-edge `max: 1` + the global budget, so a
still-tautological SPEC hard-fails cleanly after one re-author pass — no ping-pong.
