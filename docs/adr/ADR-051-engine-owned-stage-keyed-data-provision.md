# ADR-051 — Engine-owned, stage-keyed data provision (persona = first instance)

**Status:** Accepted (2026-07-26)
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
`stage_definitions.<stage>.persona: <id>` for single-pin stages, or the `map over: agents`
element id for the fan-out lenses. `core/pipeline` treats this as opaque per-stage data via a
name-mangled accessor — a drop-in copy of the existing `template_stage_router_tier`
(`core/pipeline/template.sh:2596`) / `template_stage_negctl_timeout` (`:2570`) lazy readers, with
**zero persona semantics in the engine mechanics**. Onboarding a fictitious stage leaves the
mechanics byte-identical, per ADR-047.

### 3. Resolve + inject at the router seam; the engine stays plugin/stage-agnostic

Injection generalizes the [ADR-049](ADR-049-vision-document-standard.md) vision-preamble seam
into one generic "inject engine-provided preamble data" mechanism at `_route_redact_prompt`.
Keyed on `ZBUILD_CURRENT_STAGE`, the router reads the declared binding, resolves it to text via a
**provider** — persona is the first provider; the resolver library `core/plugin-registry/persona.sh`
supplies `id → perspective` — and prepends that text generically. The provider indirection keeps
`core/pipeline` (the mechanics) free of any persona-specific code; the router, which already owns
tier/timeout/redaction/vision resolution, hosts the generic injection. Future elements (tier,
model) register as additional providers on the same seam — no new injection path per element.

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
`ZBUILD_<STAGE>_PERSONA` env  >  template `stage_definitions.<stage>.persona`  >  manifest default
>  **generic default persona**. The first non-empty binding wins; a divergent env override against
a template value is auditable, consistent with `_route_resolve_knob` (`route.sh:457`).

### 6. Injection order: through redaction

The resolved perspective is prepended **before** the single `apply_scope_redaction` pass, at the
same point as the vision preamble, so it is scope-checked like all model-bound text
([ADR-043](ADR-043-redaction-by-construction.md) / [ADR-004](ADR-004-redaction-chokepoint.md)) —
no bypass of the chokepoint, one redaction pass, covering both model paths by construction.

### 7. Framing-migration: the plugin pins move to the template

The stage plugins **drop** their hardcoded `persona_stage_framing` calls (swept in #1604); the
bindings (design→architect, plan→product-owner, impact→architect, build→developer) **move to the
template** as declared data. A **generic default persona** supplies the byte-identical baseline
when no binding resolves, reproducing each stage's current `_task_intro` text verbatim (note that
`persona_stage_framing` joins with `\n\n{task}` and build's baseline carries literal newlines,
`plugins/agent/build/lib/prompt.sh:31`). This is the outcome that actually *removes* 1.2's
hardcoding rather than shadowing it, and it makes double-framing structurally impossible. The
alternative (additive specialization) is rejected below.

### 8. Boundary and breadth

Once codified, **no plugin resolves its own persona (or tier)** — this boundary is lint-enforced
(a grep-clean check landed with the injection/generalization work). Persona is normative now;
tier/model/timeout/max_turns/redaction follow the identical declared-data + provider pattern, with
tier/model codified under EPIC #1308.

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
