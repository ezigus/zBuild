[Phase 0/F] migrate the review-lens plugin to contract v2

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/review-lens` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

## What this plugin adopts

- **v2 result file** (#1821) — `result_contract: 2`, and mandatory `verdict`, `disposition`, `reason`. Anything this plugin currently communicates through a sidecar, an event, or a bare exit code moves into the result; plugin-specific detail goes under `data`, namespaced.
- **`disposition`** (#1822) — the plugin declares *how* it stopped. It no longer decides its own retry policy; the engine's response table does that.
- **rc ∈ {0,1}** (#1823) — every other exit code this plugin returns today is expressed as a `disposition` instead.
- **`valid_verdicts`** declared in the manifest and enforced (#1708) — a verdict outside the declared set becomes a structural failure.
- **Router budgets** in the manifest (#1816) rather than resolved only from the template.
- **A `primary: true` output** declared in the manifest. Prerequisite for #1850: `no primary declared -> pass` cannot be flipped until every dispatched stage has one (only 25 of 47 manifests do today). If this plugin already declares one, say so and move on.
- **`provides.events`** declared (#1717) and **`provides.role`** declared (#1704).
- **Name-matched inputs** (#1825) with the engine resolving paths (#1826). The manifest declares only the artifact `id` and `required:` — **no producer stage, no path, no type** — and every path this plugin constructs in code is deleted. *(Amended 2026-08-12 by #1768: this read "`from:`-style inputs", i.e. the consumer naming its producer as `from: <stage>.<output_id>`. ADR-055 §1 removed that — the producer name is redundant given output-id uniqueness, and it could not express a backwards edge. Any `source: artifacts` or `source: cycle_feedback` input in this plugin becomes an ordinary name-matched input.)*
- **`cleanup`** (#1829) — if the plugin holds live resources, `release` frees them; if it has nothing to free, the hook is absent and that is recorded, not implied.

## Folds in

Advisory by design: a lens that finds nothing and a lens that failed to run must be distinguishable, which today they are not. Under v2 that is the difference between `disposition: complete` with an empty finding set and `disposition: broken`.

That distinction is the precondition for fixing **#1753** — zero collected lenses yields `merge_readiness: ready`, because jq's `all()` on an empty array is true, so a total review outage reads as a clean bill of health.

## Acceptance

- [ ] The plugin writes a conformant v2 result on **every** exit path — success, failure, and interruption.
- [ ] `valid_verdicts` is declared and every verdict the plugin can emit is in it; a test drives each one.
- [ ] The plugin constructs no artifact paths in code — assert by grep over its `plugin.sh`.
- [ ] Router budgets resolve from the manifest, and the template override still wins where one is set.
- [ ] Behaviour is unchanged for a passing run — a before/after golden diff on the stage's own output.
- [ ] The manifest declares a `primary: true` output (or the issue records why this plugin is not dispatched as a stage).
- [ ] `npm test` green with the tree committed first, so the mutation tier engages.
- [ ] Reddens at the merge-base.

Refs #1819, #1821, #1822, #1823, #1824, #1825, #1826, #1829, ADR-054, ADR-055.




---

## ALSO LAND HERE — two items that need this plugin open (from #2035, #2032)

This migration opens `review-lens`. Two other pieces of work touch the same file, and
doing them here is one pass instead of three.

### 1. The shared reply parser (#2035) — a live defect

`plugins/agent/review-lens/plugin.sh:224` still reads the model's reply with bare
`extract_first_json_object`, with no schema gate and no recovery. That helper is
**LAST-wins**: it returns the last top-level balanced object in the response. A model
that emits its real answer and then appends a sign-off containing braces loses the
whole review pass — where `plan`, `monitor` and `security-lens` recover it.

ADR-028 claimed this migration was already done for these stages. It was not; the
ADR text was corrected in PR #2037, and #2035 is the code gap it concealed.

Route the rc=0 parse through `_llm_envelope_parse --schema-gate` with a
`<stage>_envelope_schema_ok` predicate, copying `security-lens`
(`plugins/agent/security-lens/plugin.sh:42` and `:140`). This works at v1 — there
is no technical dependency on the migration; it is here purely to avoid a second pass.

**Do not** collapse onto `impact`'s parser: ADR-060 records why its two-phase
selection is deliberately stricter.

**Keep the visible-failure behaviour exactly as it is.** On a genuinely unparseable
reply `review-lens` emits `review_lens.unparseable` and records "the model returned
unparseable JSON, so this lens reviewed nothing … Absence here is not evidence of a
clean change." Recovery must mean fewer lenses report nothing — never that a failed
lens goes quiet.

### 2. Tell the model its limits (ADR-063 §1, from #2032)

Add the budget block, sourced from the values that enforce it —
`_route_resolve_timeout` (`core/router/route.sh:659`) and
`_route_resolve_max_turns` (`:671`). Never a hand-copied number: a literal drifts
from what actually kills the call.

With v2 in place here, this stage can also emit `disposition: exhausted` when it
runs out (ADR-063 §3) — the engine already responds to that word
(`disposition.sh:97` → `escalate`, then `route.sh:749` retries at +50%), and
nothing has ever produced it.
