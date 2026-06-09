# ADR-017: Per-Stage Router Configuration

**Status:** Accepted (2026-05-29)
**Date:** 2026-05-29

## Context

The router (`core/router/route.sh::route_to_model`) treats every LLM call
identically: same timeout, same tier resolution path, same budget posture,
regardless of which pipeline stage invoked it. The single global default
at `core/router/route.sh:48`:

```bash
local secs="${ZBUILD_ROUTER_TIMEOUT:-300}"
```

is the only knob, and the only escape hatch is the session-wide
`ZBUILD_ROUTER_TIMEOUT` env var.

That uniformity was fine when every stage's prompt was roughly the same
shape. It is no longer fine. Stages have very different workloads:

- **plan** sends a small prompt (intake goal + scope context), gets a
  structured JSON response, typically completes in 100–180s on Sonnet.
  300s is comfortable headroom.
- **build** sends the full plan + scope manifest + redaction context and
  expects a multi-file diff response. Empirically the prompt is the
  largest in the pipeline, the response is the largest, and 300s catches
  the easy cases but not the median.
- **review** sends a verdict prompt with the plan + diff and expects a
  small `{verdict, confidence, ...}` payload. Faster than plan.

Dogfood evidence from run `20260529124603-91950` on the live install:
`router.error rc=124 reason=claude_cli_failed` at exactly 300s after the
build-stage route. Retry returned an empty response (`input_tokens=0
output_tokens=0`). Build plugin wrote an empty diff. Review correctly
blocked. The chain was faithful, but the operator burned 5+ minutes of
wall-time before learning that the build prompt needed more headroom.

The naïve fix is to raise the global default. That's blunt:

- 300 → 600 doubles the failure-detection latency on plan and review
  stages where the original 300s was already generous.
- It doesn't actually express the operator's intent. The intent is
  *"build needs more time than plan does"*, not *"every stage gets more
  time."*

The architectural pattern for this kind of per-stage knob is already
established by ADR-015 v3, which added `io.destinations`, `io.tail_lines`,
and `io.redact` to the per-stage template block. Each is plumbed through:

1. Awk parser arm in `_tpl_parse_stage_data` (template.sh:107-145).
2. Name-mangled env var `_TPL_STAGE_<KNOB>_${safe_id}`, exported for
   plugin subshell inheritance (#448 lesson).
3. Accessor function `template_stage_<knob>` (template.sh:152-160).
4. Validator (`_tpl_validate_io_knobs`, template.sh:119-150).
5. Consumer reads the accessor with a fall-back chain.

Adding a per-stage **router** configuration surface in the template is
the same pattern applied to a new sibling block. The router becomes
stage-aware via the already-exported `ZBUILD_CURRENT_STAGE` (PR #438).

## Decision Factors

**Global default vs. per-stage knob.**

- Global default: zero new code, but slow-failures on plan/review when
  raised, and doesn't match operator mental model. Rejected.
- Per-stage knob in template: ~150 LOC, matches ADR-015 v3 pattern,
  expresses the actual intent, ships sane defaults. Accepted.

**Separate ADR vs. ADR-015 amendment.**

- ADR-015 amendment: smaller. But ADR-015 is about *observability* (what
  the stage did, where to send the record). Router configuration is a
  different concern — it's about *how the stage's LLM call is shaped*.
  Folding them obscures both ADRs.
- Separate ADR (this one): makes the router-becomes-stage-aware contract
  change explicit. Accepted.

**`router:` block vs. flat `router_timeout_s:` field.**

- Flat field: simpler v1, but every future knob (tier, budget,
  model_override) needs another flat field at the stage level. Schema
  flattens, intent gets lost.
- Block (`router: { timeout_s: N, ... }`): mirrors the existing `io:`
  block. Future knobs slot in naturally without another ADR. Accepted.

**Override precedence: who wins?**

- Three layers: per-stage template, global env var, compile-time default.
- Per-stage MUST win the env var (otherwise operators can't pin a build
  stage's timeout regardless of what the env says).
- Env var MUST win the compile-time default (existing behavior; CLI
  invocations outside a pipeline still respect it).
- Decision: per-stage > env var > compile-time default.

**Default value retention.**

- Compile-time default stays at 300s. Single-shot CLI invocations and
  any stage that doesn't pin a template value still get the existing
  behavior. No silent behavior change for unmigrated templates.

## Decision

1. **Per-stage router configuration surface in the pipeline template.**
   New optional block under each stage:

   ```yaml
   stages:
     - id: build
       gate: auto
       roles: [builder]
       io:
         destinations: [file, stdout]
         tail_lines: 200
       router:
         timeout_s: 900
   ```

   First knob: `timeout_s`. Future knobs reserved (see §8). Absent
   `router:` block → no per-stage override (existing precedence kicks
   in).

2. **Resolution precedence** (highest first):
   1. Per-stage template `router.<knob>`.
   2. Global env var `ZBUILD_ROUTER_TIMEOUT` (and analogous future env
      vars).
   3. Compile-time default in `core/router/route.sh` (300 for
      `timeout_s`, unchanged).

3. **One chokepoint helper for resolution** — the router reads the
   resolved value via a small lookup that captures the precedence rule
   in one place. Pattern:

   ```bash
   _route_resolve_timeout() {
       local v
       v="$(template_stage_router_timeout "${ZBUILD_CURRENT_STAGE:-}" 2>/dev/null || true)"
       [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
       printf '%s' "${ZBUILD_ROUTER_TIMEOUT:-300}"
   }
   ```

   Centralising the precedence in `_route_resolve_*` helpers (rather
   than inlining at every consumer) means the rule is checkable by a
   future linter the same way ADR-004's redaction chokepoint is, and
   the same shape that ADR-015 used for `capture_stage_io`.

4. **Template parser extension.** Awk arm in
   `_tpl_parse_stage_data` for `router.timeout_s` inside a per-stage
   `router:` block. Pipe-delimited stage emit grows from 6 fields to 7
   (`id|roles|strategy|io_dests|io_tail|io_redact|router_timeout`).
   Name-mangled storage as `_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}`,
   **exported** alongside the other `_TPL_STAGE_*` vars (#448 lesson:
   plugin subshells must inherit). Accessor `template_stage_router_timeout`.

5. **Validator.** Reject non-integer values and values outside
   `1..3600` at template load. Actionable error: `template: router.timeout_s for stage '<id>' must be integer in 1..3600, got: <val>`.

6. **Defaults shipped in `config/templates/standard.yaml`:**

   | stage | `router.timeout_s` | rationale |
   |---|---|---|
   | intake | (not set) | no router call — uses `gh issue view`, command-kind |
   | plan | 300 | structured JSON, observed 100–180s baseline (#424 evidence) |
   | build | 900 | plan + scope + redaction context, multi-file diff output, observed timeout at 300s (run `20260529124603-91950`) |
   | review | 300 | short verdict JSON, faster than plan |

   Future stages adopt explicit values when they wire into the router.

7. **Audit trail.** `model.route` event payload gains a `timeout_s`
   field showing the resolved value that was in effect for the call.
   Schema entry added to `config/event-schema.json`. Operators can
   answer "did my override take effect?" from `events.jsonl`.

8. **Out-of-scope-for-v1 but reserved as siblings in the `router:` block.**
   The ADR enumerates these so future PRs that add them don't need a
   new ADR — they implement the named knob using the same plumbing:

   - `router.tier_default` (override `ZBUILD_PLAN_TIER` etc.)
   - `router.budget_usd` (per-stage cost cap)
   - `router.model_override` (pin a specific model for one stage)

   Each future addition: validator update, accessor, `_route_resolve_*`
   helper, and `model.route` event field. Same shape as `timeout_s`.

## Consequences

**Positive:**

- Build stage's 5-minute median wall-time gets the room it needs without
  punishing plan/review's faster failure-detection.
- Operator intent (`"build needs more time than plan"`) becomes
  expressible directly in the template rather than via an awkward
  global env var that affects everything.
- The audit trail (`model.route` events) shows the resolved per-stage
  value, so a future operator debugging "why did this call take so
  long?" can answer it from the events log without re-reading config.
- The pattern (parser + name-mangled env var + accessor + validator)
  is already proven by ADR-015 v3; this is a deliberate small step.
- Reserved sibling knobs (`tier_default`, `budget_usd`,
  `model_override`) get implemented without further ADR overhead,
  reducing the future paperwork cost.

**Negative / costs:**

- Template schema grows. Operators authoring custom templates have
  more knobs to keep track of. Mitigation: per-stage `router:` is
  optional; absence preserves existing behavior.
- Pipe-delimited contract in `_tpl_parse_stage_data` grows from 6 to 7
  fields. Every consumer of the parsed stage data must update. (The
  same kind of churn ADR-015 v3 already absorbed without regression.)
- One more variable that has to be exported for plugin subshells
  (`_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}`). Lesson from #448 says we
  must export, and lock it via a regression test that calls `printenv`
  in a child shell after `load_template`.
- `model.route` event schema change is a touch of schema churn. Mitigation:
  the field is additive (schema-as-warn passes unknown fields).

**Open follow-ups (file separately if/when needed):**

- Per-stage `router.tier_default`, `router.budget_usd`,
  `router.model_override` (covered by §8; implementation follows the
  same plumbing).
- Per-stage `router.retry_strategy` (would change the router's
  retry-on-rc=1 behavior; bigger semantic change, separate ADR).
- A CLI subcommand `zbuild template show <id>` that prints the
  resolved per-stage router config so operators can verify before a
  run.

## References

- [ADR-013](ADR-013-canonical-stage-list.md) — canonical stage list;
  this ADR's per-stage knobs apply across the same set.
- [ADR-015](ADR-015-stage-io-capture.md) — the per-stage knob pattern
  this ADR mirrors (`io.destinations`, `io.tail_lines`, `io.redact`).
  Same parser arm, same name-mangled env var, same export-for-plugin
  rule.
- `core/router/route.sh:48` — the current single-global-default line
  this ADR replaces with a precedence-aware resolver.
- `core/pipeline/template.sh:107-145` — awk parser to extend.
- `core/pipeline/template.sh:117-126` — name-mangled env var export
  pattern (#448 lesson: must export for plugin subshells).
- `core/pipeline/template.sh:152-160` — accessor pattern to mirror.
- `core/pipeline/template.sh:119-150` — validator pattern.
- `config/templates/standard.yaml` — defaults landing target.
- `config/event-schema.json` — `model.route` event extension.
- #424 (closed) — the previous router-timeout adjustment (120s → 300s).
  This ADR is the right architecture for what #424 attempted as a
  global default.

## Implementation Notes (Accepted — 2026-05-29)

Implemented in **PR for #455** on branch `feat/455-per-stage-router-timeout`:

- Awk parser extended in `core/pipeline/template.sh::_tpl_parse_stage_data`
  with a new `router:` block arm and `timeout_s:` field; pipe-delimited
  emit grows from 6 to 7 fields.
- Validator `_tpl_validate_io_knobs` extended with a 4th nameref arg
  (`rtimeouts_ref`) and rejects values outside `1..3600` with the
  actionable error `template: router.timeout_s for stage '<id>' must be
  integer in 1..3600, got: <val>`.
- Name-mangled env var `_TPL_STAGE_ROUTER_TIMEOUT_${safe_id}` is appended
  to the existing `export` statement (#448 lesson — plugin subshells
  must inherit; locked by `Tv3-16` and the
  `tests/integration/router-timeout-precedence-e2e-test.sh` subprocess-
  boundary test).
- Accessor `template_stage_router_timeout` added.
- Router gains the generic precedence chokepoint
  `_route_resolve_knob <accessor_fn> <env_var> <default>` and a concrete
  `_route_resolve_timeout` (per-stage > `ZBUILD_ROUTER_TIMEOUT` > 300s).
  When per-stage and env both set with different values, a
  `router.timeout.override_ignored` event is emitted for audit.
- `model.route` and `model.outcome` events both carry the resolved
  `timeout_s` field. `router.timeout.override_ignored` added to
  `config/event-schema.json::known_types`.
- `config/templates/standard.yaml` ships defaults: plan=300, build=900,
  review=300; intake stays without a router block (no router call).

Out-of-scope-for-v1 siblings reserved in §8 (`tier_default`, `budget_usd`,
`model_override`) are deliberately *not* implemented here — they will
reuse the `_route_resolve_knob` chokepoint and the same parser/validator/
accessor pattern when they land.

A separate issue tracked alongside this ADR (**#456 — intake refuse-on-closed**)
is *not* covered here — it's a behavioral guard in the intake plugin, not a
router contract change, and has no interaction with this ADR's status.

## Amendment 1 (Wave 19-M, #762/#763) — `router.max_turns` accepts 0 sentinel

`router.max_turns` uniquely accepts `0` as a sentinel meaning "omit the
`--max-turns` flag from claude argv" (semantics per ADR-018 Amendment 1).
Other `router.*` knobs (`timeout_s`, `max_iterations`, future additions) retain
their strict positive lower bounds. The validator-rejection invariant for
`1..200` is explicitly widened to `0..200` for this knob only.

The sentinel is honored at all three resolution points: per-stage template
field (`router.max_turns: 0`), env-var (`ZBUILD_ROUTER_MAX_TURNS=0`), and
the compile-time default (still `25`; `0` would only apply if the default
itself ever changed — see ADR-018 Amendment 1 forward-compat note).
