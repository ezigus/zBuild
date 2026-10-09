[bug] route_to_model_loop emits no model.route and no model.outcome — design and build are invisible to per-call tier, provider and cost attribution

> **Updated 2026-10-08** (Phase 2 re-verification against main 2ae004fa, checked in code, not from this text): defect re-confirmed — `route_to_model_loop` (`core/router/route.sh:1607`) never calls `_route_emit_model_route` (`:923`) or `_route_emit_outcome` (`:1334`); the sync path does (`:199`, `:240`). Line refs moved ~100 lines throughout. **Not in the body:** the loop never fills `_ROUTE_INPUT_TOKENS` or the cache-token variables per iteration (parsed only on the sync path, `:1286-1302`), so a `model.outcome` emitted from the loop needs that parsing too or it reports zeros. #1699 is still open, so "land before #1699" stands. Conflicts textually with #1752 in the same function.

> **Updated 2026-09-29** (Initiative 1.3 alignment audit, main 900db6b0): the loop path now writes a ledger row per iteration (420e7964, #2209) and detects rate limits (#1723, closed); what remains is that it emits no `model.route` and no `model.outcome`. Title changed to match; line refs refreshed, and cost is now provider-reported rather than computed from rates.

Part of #1795 (Phase 2 — stop the silent waste).

*Re-parented: originally filed under #1600, closed when Initiative 1.3 (#1818) reorganised into phases.* Found while assessing run `20260805010803-2353` (issue #1715, PR #1725).

**Classification: ENGINE (router) — `core/router/route.sh`. The routing and outcome events are wired into one of the two call paths.**

## What has landed since filing
- **Ledger:** `route_to_model_loop` now calls `_route_record_call` + `_route_update_ledger` on every iteration, including failed ones (`route.sh:2073-2074`, `:2201-2202`) — 420e7964 / #2209, which also made cost provider-reported (no prices in `config/models.json`).
- **Budget:** the loop checks `_route_check_budget` before every iteration (`route.sh:1632`).
- **Rate limits:** `_router_is_rate_limit` is reached from the loop (`route.sh:1956`, `:2075`) — #1723 (closed); a rate-limited timeout is not retried in the loop (21239442); a rate limit ends the run (#2116).

## Problem (remaining)
The router's routing and outcome events are emitted only from `route_to_model()` (`route.sh:135-240`):

```
core/router/route.sh:173   _route_emit_model_route "$tier" "$secs"
core/router/route.sh:214   _route_emit_outcome     "$tier" "$secs"
```

(emitters at `route.sh:883` and `:1273`). `route_to_model_loop()` (`route.sh:1501` onward) calls neither. It is the path `design` and `build` run on.

## Evidence
Run `20260805010803-2353` (at filing):

| stage | path | `model.route` | `model.outcome` | output tokens |
|---|---|---|---|---|
| plan | sync | ✅ | ✅ | 6,020 |
| impact | sync | ✅ | ✅ | 9,229 |
| 6 review lenses | sync | ✅ ×6 | ✅ ×6 | 19,286 |
| **design** | **loop** | ❌ | ❌ | **17,930** |
| **build** | **loop** | ❌ | ❌ | **25,103** |

Still true on main: run `20260928102849-23575` (issue #1847) has `model.route`/`model.outcome` for plan, impact, spec-coverage ×3, test-author, spec-correspondence and issue-acceptance — and none for `design` (15 `loop.iteration`) or `build`.

The loop path is not silent, which is what makes this easy to miss: it emits `loop.iteration`, `loop.complete` (carrying `model_id` and cumulative `input_tokens`/`output_tokens`) and now a ledger row. But `loop.complete` carries no tier, provider or cost, and the ledger row is a bare float (#1699), so the event stream cannot attribute the biggest calls to a tier, provider or cost.

## Fix
1. **Emit `model.route` and `model.outcome` from the loop**, once per call (per iteration), from the same emitters the sync path uses.
2. **Assert reachability from both paths**, so this cannot silently regress to one caller again. #1237 was closed as fixed for the rate-limit detector and remained broken on the loop path (#1723); the identical shape here is the reason to pin it with a test rather than a comment.

Land before #1699, which reshapes rows that should carry this attribution.

## Acceptance
- [ ] A `route_to_model_loop` call emits `model.route` with tier, model id and provider — asserted with a stubbed claude; reddens at the merge-base.
- [ ] A `route_to_model_loop` call emits `model.outcome` with input/output/cache token counts and the provider-reported `cost_usd`.
- [ ] Per-iteration granularity: an N-iteration loop produces N route/outcome events, matching its N ledger rows.
- [ ] Guard: `route_to_model` behaviour is unchanged — existing route-unit-test assertions still pass.
- [ ] A test asserts both entry points reach the shared emitters, so a future path cannot bypass them undetected.
- [ ] Full suite green.

Where: `core/router/route.sh:135-240` (sync path), `:883` / `:1273` (the two emitters), `:1501-2340` (loop path). Refs #1723, #1699, #1237, #1600, ADR-003.

---

## Contract

This issue touches a surface that **[ADR-054](../blob/main/docs/adr/ADR-054-stage-contract.md) / [ADR-055](../blob/main/docs/adr/ADR-055-inter-stage-data-contract-v2.md) redefine** (Phase 0, #1819). Implement against the contract, not against today's engine — if the two disagree, the ADR wins.

- ADR-054 §4-§6 — the engine acts on `disposition`, not on a re-derived verdict string.
- Initiative goal and the domain checklist this must satisfy: #1818
