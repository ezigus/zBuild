# ADR-051 — Engine-owned, stage-keyed data provision (persona = first instance)

**Status:** Accepted (2026-07-26); amended 2026-10-12 (§3, §6, §7, §8: the provider delivers the persona; no stage frames one); amended 2026-11-14 (§2, §3, §5, §7: each model call runs as the persona its stage's manifest names for it, not listed here; §9: what a perspective holds)
**Issue:** #1303 (Initiative 1.3 — "Personas as Data", #1551)
**Related:** [ADR-047](ADR-047-stage-agnostic-mechanics.md) (stage-agnostic mechanics),
[ADR-049](ADR-049-vision-document-standard.md) (generic preamble injection),
[ADR-043](ADR-043-redaction-by-construction.md) / [ADR-004](ADR-004-redaction-chokepoint.md)
(redaction chokepoint), [ADR-038](ADR-038-adversarial-multilens-review-report.md) (framing is
behavior, not profession), [ADR-016](ADR-016-per-repository-template-resolution.md) /
[ADR-032](ADR-032-per-repo-prompt-overrides.md) (per-repo `.zbuild/` overlay),
[ADR-024](ADR-024-subprocess-env-isolation.md) (subprocess env isolation / plugins-root hermeticity),
[ADR-017](ADR-017-per-stage-router-config.md) (per-stage router config),
[ADR-020](ADR-020-inter-stage-data-contract.md) (inter-stage data contract),
[ADR-028](ADR-028-shared-llm-agent-framework.md) (shared LLM-agent framework).

> **Scope.** This contract is **normative for persona** and *descriptive* for the other
> stage-keyed data elements (tier, model, timeout, max_turns, redaction). Persona is the first
> element resolved-and-injected by this mechanism; tier/model are codified later under EPIC #1308.

## Context

The pattern "the engine resolves cross-cutting data keyed on the current stage, and the plugin
stays ignorant" already exists but is implicit and partial. Today only `timeout`, `max_turns`,
and `redaction` are engine-side (`core/router/route.sh` — `_route_resolve_timeout`,
`_route_resolve_max_turns`, `_route_redact_prompt`); **persona and tier are still resolved and
composed inside the stage plugins.** Each of design/plan/impact/build hardcodes its own persona
(`persona_stage_framing architect|product-owner|developer …`) and its own fallback framing.

There is no documented contract for (a) what a plugin may vs. must-not resolve, (b) how a new
cross-cutting element (persona) is added, or (c) how any of this stays compatible with the
**stage-agnostic mechanics rule** ([ADR-047](ADR-047-stage-agnostic-mechanics.md)): `core/pipeline`
knows only four composition operators (leaf / sequence / parallel / cycle) and reads everything
else as *declared data* via name-mangled accessors — it must never branch on a stage name or a
plugin's semantics, and this is guarded by a fictitious-stage byte-identical CI harness (e.g.
`tests/unit/verdict-stage-agnostic-test.sh`, `tests/unit/template-resolvability-preflight-test.sh`).

Two facts constrain the design:

- **Framing is behavior, not profession.** Initiative 1.2 (#1568) removed the `"You are a {role}"`
  profession preamble. A persona now contributes only its behavior-first `perspective`;
  `persona_stage_framing` emits `{perspective}\n\n{task}` with `role` deliberately excluded
  (`core/plugin-registry/persona.sh:77-83`). The engine must inject the **perspective**, never a
  role sentence.
- **There is a precedent for generic, data-driven prompt injection.** The vision preamble
  ([ADR-049](ADR-049-vision-document-standard.md)) reads a declared data source, resolves it to
  text, and prepends it generically inside `_route_redact_prompt` (`core/router/route.sh:265,276`)
  **before** `apply_scope_redaction` (`:292`) — covering both model paths (`route_to_model:75`,
  `route_to_model_loop:1216`), memoized, byte-capped, fail-open, idempotent, with **no
  stage/plugin branching**. Persona injection should generalize this seam.

## Decision

### 1. Personas are generic, reusable, user-extensible data

A persona is a `kind: persona` plugin (`plugins/persona/<id>/manifest.yaml`) carrying `role`
(data, never injected) and `perspective` (the behavior-first directive that *is* injected). A
persona is **not owned by a stage** — any stage may use any persona, and a user may author their
own personas (see §4). The engine never enumerates the persona set.

### 2. The binding is template data; `core/pipeline` passes it through blind

Which persona a stage uses is a **declaration in the template**, not code in a plugin:
`stage_definitions.<stage>.persona: <id>` (or `persona:` in the stage's own section) for a
stage, and, for a `type: map` group, each element's own `persona:` — an element carries its
settings the way a stage does (`elements: - id: <element>` / `persona: <id>`). A persona is never
inferred from an element's name: an element that names none runs as its stage's pin, else
`generic` (amended 2026-10-12). Every persona the template names must exist (§4): the startup
preflight refuses a run whose template names one that is in neither the repository's overlay nor
the install, in its default mode too, so a misspelt id never quietly runs as `generic`. `core/pipeline` treats this as opaque per-stage data via a
name-mangled accessor — a drop-in copy of the existing `template_stage_router_tier`
(`core/pipeline/template.sh:2596`) / `template_stage_negctl_timeout` (`:2570`) lazy readers, with
**zero persona semantics in the engine mechanics**. Onboarding a fictitious stage leaves the
mechanics byte-identical, per ADR-047.

*Amended 2026-11-14 — each call's persona is in its stage's manifest.* A stage's manifest lists every
model call it makes (`calls:`, ADR-017 §12), and beside it names the persona each call runs as:

```yaml
calls:
  main: [read-files, edit-files, run-commands, web-search, subagents, todo-list]
  coverage: [read-files, read-git, web-search, subagents]
personas:
  main: architect
  coverage: quality-assurance
```

A call that judges work is not run as the persona of the work it judges: design's check of its own
SPECs ran as the architect who wrote them, and test-author's check of its assertions as the test
strategist who wrote them. `validate_manifest` refuses an entry for a call the manifest does not
list, or one that is not a persona id; the startup preflight refuses a persona a manifest names
that exists nowhere, as it does a template's. The shipped templates pin no stage's persona; a map
group's element still names its own, because one plugin serves every element. The direction is
one way: a stage names the persona it runs as, and a persona names no stage (§9).

### 3. The router resolves the persona; the provider delivers it (amended 2026-10-12)

Every model call a dispatched stage makes runs as a persona. The router resolves it
(§4, §5) keyed on `ZBUILD_CURRENT_STAGE` and the call (`ZBUILD_ROUTE_CALL`, `main` when unset;
amended 2026-11-14) — for a map element, the persona the template names for
it (§2) — and the **provider module that calls the
model decides how it reaches the model** (`core/router/persona-delivery.sh`). A provider that can
run the call as an agent defines `provider_<name>_persona_args` and gets the persona's id, summary
and `perspective`: Anthropic passes `--agents <json> --agent <id>`. A provider that cannot gets
the persona as the prompt's first section, `## Who you are`, followed by the stage's contract
prompt (ADR-067 §8). A review lens is a stage like any other: the review-lens stage writes one job and gives every lens the same evidence, and the question a lens asks is its persona's — there is no lens text table and no per-lens evidence (amended 2026-10-12). Either way, every call of a stage's model loop runs as the persona; a model
call made outside any stage runs as none. `core/pipeline` holds no persona code (ADR-047).

### 4. Discovery spans the installed tree AND the target-repo overlay

Personas are resolved from **both** the installed plugins root
(`${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}`, exactly what `discover_plugins`
(`core/plugin-registry/discovery.sh:22`) uses today) **and** a per-repo overlay under the target
repo, following the established `.zbuild/<category>/` convention of
[ADR-016](ADR-016-per-repository-template-resolution.md) (templates) and
[ADR-032](ADR-032-per-repo-prompt-overrides.md) (prompts): resolve the repo root as
`${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}`, read the overlay
silent-on-absent, and let the repo overlay **override** the installed entry for the same id. This
makes personas user-extensible like any other plugin. Today `find_persona` scans a single root
and cannot see a repo-local persona (`core/plugin-registry/persona.sh:24`); closing that gap is
net-new work in the resolver (#1305). The overlay must be an **additional** scan root, never
leaked via `ZBUILD_PLUGINS_ROOT` into nested runners — preserving
[ADR-024](ADR-024-subprocess-env-isolation.md) / #1274.

### 5. Resolution precedence

Mirroring `resolve_tier` (`scripts/lib/tier-resolve.sh:55`):
`ZBUILD_<STAGE>_PERSONA` env  >  a map element's own `persona:`  >  template `stage_definitions.<stage>.persona` (the
`main` call's only)  >  the manifest's persona for the call (`personas:`, amended 2026-11-14)  >  **generic default persona**. The first non-empty binding wins; a divergent env override against
a template value is auditable, consistent with `_route_resolve_knob` (`route.sh:457`).

### 6. The persona goes through redaction (amended 2026-10-12)

The persona's text is model-bound and passes through `apply_scope_redaction` like the prompt
([ADR-043](ADR-043-redaction-by-construction.md) / [ADR-004](ADR-004-redaction-chokepoint.md)):
as `## Who you are` it is part of the prompt the router redacts; given to the provider as an agent
it is redacted on its own first, so the prompt's `redaction.applied` stays the last event before
the call. A persona that cannot be redacted is not sent.

### 7. The persona is data, never prompt text; no stage frames one (amended 2026-10-12)

The stage plugins no longer call `persona_stage_framing` (#1604; the function is removed with its
twin `resolve_persona_charter`). Which persona each call runs as is its manifest's to say (§2), and
this ADR does not list them: a persona knows nothing of the stages that use it (§1, §9) (amended
2026-11-14: this section listed template pins, and the list had gone stale — it named stages that no
longer exist). A stage keeps its own
job sentence in its own `## What you own` — it is the stage's task, not a persona. A call that names
no persona runs as `generic`. A review lens keeps its own question as its charter; a lens persona's
`perspective` is that same question, delivered by the provider.

### 8. Boundary and breadth

**No plugin resolves or frames its own persona**: no stage prompt carries the perspective of a
persona a shipped template pins, and no plugin calls `persona_stage_framing` (amended 2026-10-12). Persona is normative now;
tier/model/timeout/max_turns/redaction follow the identical declared-data + provider pattern, with
tier/model codified under EPIC #1308.

### 9. What a perspective holds (amended 2026-11-14)

A perspective says **what to look for**, as rules of thumb: the cases to check, the mistakes to catch,
how to grade what is found. It is **not an identity**: no "you are a …", no "expert". It speaks of
**the work, never the pipeline**: no stage, plan, pipeline, manifest or lens, because one persona
serves every stage that pins it (§1) and words about one stage's work are wrong in the next. A rule
goes where it holds:

| A rule that… | goes in |
|---|---|
| holds for anyone doing that kind of work (test the false case of every condition) | the persona's perspective |
| is about one stage's output (put a test in the files the issue names) | that stage's `## What you own` |
| a script can check | a check, not a sentence |

*Why.* Studies of persona prompts agree that a role or identity line does not make a model more
accurate, and an expert label can make it less so: Zheng et al. found personas in system prompts gave
no gain over none across 4 model families and 2,410 questions, and picking the best one was no better
than chance ([arXiv 2311.10054](https://arxiv.org/abs/2311.10054)); Wharton's *Playing Pretend*
found expert personas, even matched to the field, did not beat no persona on six models, and advised
task-specific instructions instead ([arXiv 2512.05858](https://arxiv.org/abs/2512.05858)); PRISM
found an expert persona scored lower on MMLU while helping format and tone
([arXiv 2603.18507](https://arxiv.org/abs/2603.18507)). Anthropic's guidance is to give the smallest
set of specific instructions, as heuristics, and add to it from the failures seen
([Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).
A perspective made of concrete rules of thumb is that; one made of virtues ("verify every invariant")
is not. Different perspectives may help reviewers find different problems (weaker evidence:
[arXiv 2605.23108](https://arxiv.org/abs/2605.23108)), which is why each lens keeps its own question.

On #1769 run 43517034037 the scope lens judged against "the plan's declared file list" — the plan
stage had been merged into design — and issue-acceptance ran as a persona that judged "a plan".

## Consequences

**Good**
- Adding or changing a persona — including a repo-local one — is a pure data change; no engine or
  plugin edit. The engine gains no stage/persona knowledge (ADR-047 preserved).
- 1.2's hardcoding is genuinely removed; double-framing cannot occur.
- One injection seam serves both model paths and every future data element (tier/model reuse it).
- The persona preamble is redacted like all model-bound text (no new bypass of ADR-043/004).

**Bad / cost**
- Requires a resolver with two-root discovery (net-new), a generalized injection seam, a generic
  default persona per migrated stage, and a sweep of the four plugin pins into the template.
- A generic default persona must exactly reproduce each stage's current baseline, or parity
  breaks — this is load-bearing and must be proven by a byte-identical golden (#1317).

## Alternatives considered

- **Additive specialization** — keep each plugin's base framing and layer the persona on top.
  Rejected: leaves 1.2's hardcoding in place and requires perpetual double-framing policing.
- **Router resolves "persona" specifically** (a bespoke persona path alongside `resolve_tier`).
  Rejected: less general than the provider seam; tier/model would each need a new injection path
  instead of registering on one generic mechanism.

## Implementation Notes (#1303)

This ADR is the gate for Initiative 1.3; the stories that codify it are `blocked-by` it:

- **#1305** — `resolve_persona` provider + generic-default fallback + **two-root discovery**
  (installed + `.zbuild/` overlay, §4).
- **#1306 (C1–C4)** — generalize the vision-preamble seam into the generic provider injection
  (§3/§6); C1 (#1314) is a `perspective` reader (not a "You are a {role}" assembler); C4 (#1317)
  proves generic-default-persona byte-identical parity + the router-only lint (§8).
- **#1604** — sweep the four hardcoded `persona_stage_framing` pins; move the bindings to the
  template (§7).
- **E (#1325 / #1351)** — lens charters as persona `perspective` data over the `agents` map; the
  router injects (§1/§3). Multi-persona design (#1351) composes generic personas per element.
- **#1318** — `_runner_validate_startup_preflight` warn-first **skeleton** (§warn-first): owns the
  violation aggregation and the render-all-at-once block (same pattern as
  `_contract_validate_pipeline`), and defaults to `warn` mode so operators see failures before
  enforcement is mandatory. Gated by `ZBUILD_CONTRACT_VALIDATOR` (`warn` / `enforce` / `off`);
  exempted in `--dry-run` / `--resume` (matching `_runner_validate_leaf_resolvability`).
  Implemented via `_runner_startup_preflight_gate` (testable gateway) in
  `core/pipeline/runner.sh`. It contributes **no checks of its own** — the concrete producers
  land in **#1320** (persona-binding existence) and **#1321** (`requires.plugins` resolution),
  each against the discriminating fixtures **#1605** pre-stages, so neither ships without a test
  that reddens at merge-base. Until then the live startup path renders nothing and returns 0.
- **Non-goals here:** tier/model resolution (EPIC #1308) and any change to `core/pipeline`
  mechanics (they stay agnostic; the binding is opaque declared data).

## References

- Stage-agnostic mechanics + fictitious-stage harness: [ADR-047](ADR-047-stage-agnostic-mechanics.md);
  `tests/unit/verdict-stage-agnostic-test.sh`, `tests/unit/template-resolvability-preflight-test.sh`.
- Generic injection precedent: [ADR-049](ADR-049-vision-document-standard.md);
  `core/router/route.sh` (`_route_vision_preamble:223`, `_route_redact_prompt:265/276`,
  `route_to_model:75`, `route_to_model_loop:1216`).
- Per-stage declared-data accessors: `core/pipeline/template.sh` (`template_stage_router_tier:2596`,
  `template_stage_negctl_timeout:2570`, accessor block `:2463-2553`); `_route_resolve_knob:457`.
- Per-repo overlay convention: [ADR-016](ADR-016-per-repository-template-resolution.md),
  [ADR-032](ADR-032-per-repo-prompt-overrides.md); `core/pipeline/template-resolver.sh:20`,
  `scripts/lib/prompt-overrides.sh`. Hermeticity: [ADR-024](ADR-024-subprocess-env-isolation.md);
  `tests/unit/plugins-root-hermeticity-test.sh`.
- Persona library: `core/plugin-registry/persona.sh:24,77-83`; `scripts/lib/tier-resolve.sh:55`.
- Redaction chokepoint: [ADR-043](ADR-043-redaction-by-construction.md),
  [ADR-004](ADR-004-redaction-chokepoint.md).
- Issue: #1303; initiative: #1551.

## Enforced by

- §1 (a persona is data: id, role, perspective; the resolvers and the live manifests) → `tests/unit/persona-resolver-test.sh`, `tests/unit/persona-kind-validation-test.sh`
- §2, §5 (the template pin picks the persona; the env override wins) → `tests/unit/persona-agent-delivery-test.sh` PA2, PA3
- §2 (a map element names its own persona, never inferred from its name; its stage's pin, else generic, when it names none; every named persona exists or the run is refused at startup; the shipped lenses each name theirs) → `tests/unit/map-element-persona-test.sh` ME1–ME6
- §3 (a lens is a stage like any other: one job, the same evidence, its question its persona's) → `tests/unit/retired-impact-review-report-inputs-test.sh` RT3
- §3 (the provider delivers the persona: Anthropic's `--agents`/`--agent`; `## Who you are` for a provider that cannot; every loop call; no persona outside a stage; a map element's declared persona) → `tests/unit/persona-agent-delivery-test.sh` PA1, PA2, PA5–PA8
- §4 (the target repository's `.zbuild/plugins/persona/<id>` before the install's; generic when none) → `tests/unit/persona-agent-delivery-test.sh` PA4; the overlay is never leaked via `ZBUILD_PLUGINS_ROOT` → `tests/unit/plugins-root-hermeticity-test.sh`
- §6 (the persona passes through the scope redaction, before the prompt's own) → `tests/unit/persona-agent-delivery-test.sh` PA10
- §7 (a stage's persona is data, not code) → `tests/unit/persona-agent-delivery-test.sh` PA9
- §2, §3, §5 amendment 2026-11-14 (each call runs as the persona its manifest names; a template pin is the main call's only; a manifest's unknown call or missing persona is refused; the shipped manifests name each call's persona) → `tests/unit/manifest-call-persona-test.sh` MP1–MP6
- §8 (no stage frames a persona) → `tests/unit/prompt-contract-every-stage-test.sh` E5
- §9 (a perspective, and the summary sent with it, is no identity line and names nothing of the pipeline) → `tests/unit/persona-perspective-test.sh` P1–P4
