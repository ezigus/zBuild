[Phase 0/F] migrate the monitor plugin to contract v2

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/monitor` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

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

Monitor's whole output is observation, so it is the clearest case for the `data` block: today's rendered strings become structured, namespaced data that a consumer can read without parsing prose. Coordinate with #1659 (engine-enforced execution bounds), whose watchdog result becomes a `disposition` rather than a generic rc.

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

## ALSO LAND HERE — tell the model its limits (ADR-063 §1/§3, from #2032)

This migration opens `monitor`, which today tells the model nothing about its turn
budget or timeout. Add the budget block while the file is open.

**Where the numbers come from:** `_route_resolve_timeout`
(`core/router/route.sh:659`) and `_route_resolve_max_turns` (`:671`) — the values
that actually enforce the limit. Never a hand-copied literal, which drifts from what
kills the call and leaves the prompt lying to the model with authority.

**With v2 in place here**, `monitor` can also emit `disposition: exhausted` when it
runs out of budget (ADR-063 §3). The engine already responds to that word —
`disposition.sh:97` maps it to `escalate`, and `route.sh:749` retries at +50% capped
at 2× (ADR-029) — and **nothing has ever produced it**, so that path has never run.

For reference, three stages already do the §1 half and are the models to copy:
`plan` (turn budget plus a 70%-of-wall-clock stop target), `impact` ("BUDGET
DISCIPLINE … you have a BOUNDED tool-call budget"), and `build` (`iter N/M`, with
each iteration committed so a kill costs one iteration rather than the stage).

## Additional context from issue comments

<!-- zbuild-run-status run_id=20260928070345-90197 -->
### zbuild run `20260928070345-90197` · issue #1847 · **running**
engine `507d524` (`main`) · started 7:03 AM ET · ceiling 1:03 PM ET (5h 59m left) · updated 7:03 AM ET
