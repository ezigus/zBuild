# ADR-003: Models as Data

**Status:** Accepted
**Date:** 2026-05-24

## Context

The legacy code references specific model names (`haiku`, `sonnet`, `opus`) directly: ~11 hardcoded sites in `legacy/scripts/sw-pipeline.sh`, plus cost tables, recruit role recommendations, and prompt fallbacks. Every time Anthropic ships a new model tier, or pricing shifts, or a different provider is added, code edits ripple through the repo.

Models are data. Their identity (haiku, sonnet, opus, gpt-4o, llama-3.1-70b), their costs, their context windows, and their capabilities all change on a quarterly cadence. Code should be stable across those changes.

## Decision

Code references models only by **tier ordinal** T0–T4. The mapping from tier to concrete model lives in `config/models.json` as data.

### Tier semantics

| Tier | Class | Latency | Cost | Typical use |
|---|---|---|---|---|
| **T0** | No LLM (Agent Booster / WASM) | <1ms | $0 | Simple transforms: var→const, add types, syntactic refactors. Skip LLM entirely. |
| **T1** | Micro | ~500ms | $0.0002/req | Simple tasks; complexity <30%; cheap fallbacks. |
| **T2** | Standard | 2–5s | $0.003–0.005/req | Default for most stages; balanced quality/cost. |
| **T3** | Heavyweight | 5–15s | $0.015–0.025/req | Complex reasoning, architecture, security audits. |
| **T4** | Experimental | varies | varies | Research, frontier-model testing, opt-in only. |

### `config/models.json` schema

```json
{
  "version": 1,
  "tiers": {
    "T0": {
      "class": "wasm",
      "handler": "agent-booster",
      "capabilities": ["syntactic-edit", "add-types"]
    },
    "T1": {
      "class": "llm",
      "candidates": [
        {
          "id": "claude-haiku-4-5",
          "provider": "anthropic",
          "context_window": 200000,
          "cost_per_input_mtok": 0.25,
          "cost_per_output_mtok": 1.25,
          "weight": 1.0
        }
      ]
    },
    "T2": {
      "class": "llm",
      "candidates": [
        {
          "id": "claude-sonnet-4-6",
          "provider": "anthropic",
          "context_window": 200000,
          "cost_per_input_mtok": 3.0,
          "cost_per_output_mtok": 15.0,
          "weight": 1.0
        }
      ]
    },
    "T3": {
      "class": "llm",
      "candidates": [
        {
          "id": "claude-opus-4-7",
          "provider": "anthropic",
          "context_window": 1000000,
          "cost_per_input_mtok": 15.0,
          "cost_per_output_mtok": 75.0,
          "weight": 1.0
        }
      ]
    },
    "T4": {
      "class": "experimental",
      "candidates": []
    }
  }
}
```

Multiple candidates per tier enable router-driven A/B testing (UCB1, Thompson) and provider failover — both already wired in legacy and preserved as keepers.

### Router contract

`core/router/route(tier, complexity, budget_state) → {model_id, provider, fallback_chain}` is the single API. Plugins request a tier (and optionally complexity); the router returns the concrete model. The router internally consults UCB1 / Thompson scoring (KEEPERS §B1.10–11) and cost ledger (B1.9).

### Manifest config refers only to tiers

Plugin manifests specify:
```yaml
config:
  tier_default: T2
  tier_max: T3       # never escalate beyond opus-class
```

A plugin that names a model directly fails manifest validation.

### Migration rule

When Anthropic / OpenAI / etc. ships a new model:
1. Edit `config/models.json` only.
2. Set `weight: 0` on the deprecated candidate to gracefully drain it.
3. Bump `version` in models.json.

No code change. No plugin change.

## Consequences

**Good:**
- Model upgrades are config edits, reviewable in PRs without touching code.
- Cost tables centralize (existing in legacy at one place; preserved).
- Multi-provider support comes for free (add candidates to a tier).
- Tests can pin to `T2` knowing the behavior is stable across model changes.

**Bad:**
- Adds an indirection layer; plugin authors must learn the tier system.
- Debugging "why did this run on opus?" requires consulting router logs (mitigated: every model selection emits a `model.route` event with full context).
- Tier semantics drift over time as model capabilities shift. We accept this; the tiers are about cost+latency class, not capability promises.

## Implementation Notes (Phase 0.5 — issue #291)

| Item | Status | PR / Notes |
|------|--------|------------|
| `config/models.json` with T0–T4 tiers | Implemented | #228 (router stub); current model IDs updated in subsequent PRs |
| `core/router/route.sh` reads tiers, emits `model.route` event | Implemented | #278, #317 (C6 precondition hardening) |
| C6 precondition: last event must be `redaction.applied` before model call | Implemented | #317 (rescoped from #289, 2026-05-26) |
| No hardcoded model names in code (tier-ordinal-only) | Implemented | enforced by convention; grep rule in CI lint |
| `model.outcome` event with token counts | Implemented | #330 (issue #94) |
| UCB1 / Thompson adaptive selection across candidates | Deferred → Phase 1 | tracked by **#29** |
| Cost-ledger offline accounting | Deferred → Phase 1 | tracked by **#28** |

## References

- [KEEPERS.md §B1.9–11](../KEEPERS.md#b1--verified-wired-carry-forward-as-core) — cost ledger, UCB1, Thompson router.
- `legacy/scripts/sw-pipeline.sh:~2563` (router block), `:837` (cost table).
- `legacy/scripts/sw-self-optimize.sh:851-893` (Thompson), `:907-955` (UCB1).

## Manifest `config.tier_default` is the single source of truth for a plugin's tier (#960/#1230/#1231)

A plugin's tier lives in **exactly one place**: `config.tier_default` in its own
`manifest.yaml`. Plugin code never hardcodes a tier literal.

**Resolution (`scripts/lib/tier-resolve.sh`):** routing plugins obtain their tier
via `resolve_tier <plugin_id> <plugin_dir>`, sourced by construction through
`core/router/route.sh` (every routing plugin sources the router). Order:

1. **Operator override wins** — `ZBUILD_<ID>_TIER` (ID uppercased, `-`→`_`;
   e.g. `review-lens` → `ZBUILD_REVIEW_LENS_TIER`). This is the documented,
   supported way to retier a plugin without touching its manifest.
2. Else the manifest's `config.tier_default`.
3. Else **fail loud** (non-zero) — a routing plugin with no declared tier is a
   bug, not a silent default. The result must match `^T[0-4]$`.

**Plug-and-play:** there is no central stage→tier map in the engine. A new
routing plugin plugs in by declaring `config.tier_default` in its own manifest —
zero engine edits.

**History / why this rule exists:** plugins used to select their tier via a
`${ZBUILD_<ID>_TIER:-T?}` literal in `plugin.sh` that *duplicated* the manifest
value, and nothing read the manifest. That literal drifted: #960 declared
`impact.tier_default: T2` but `plugin.sh` kept a stale `:-T1}` fallback, so
impact ran on T1 (haiku) and timed out (rc=124, #1230). #1231 retired all nine
literals in favor of `resolve_tier`. Behavior was byte-identical at the cutover
(every literal already equalled its manifest); the value is removing the drift
class. `tests/unit/impact-tier-test.sh` now enforces the invariant: **no
`plugin.sh` may contain a `${ZBUILD_*_TIER:-T[0-4]}` literal**, and `resolve_tier`
must return each plugin's manifest `config.tier_default`.
