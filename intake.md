[Phase 0/F] migrate the design plugin to contract v2

Part of #1819 (Phase 0 — the stage↔engine contract). Member of the **F set** — one plugin per PR, each independently verifiable.

Migrate `plugins/agent/design` to contract v2. The engine reads v1 and v2 side by side (#1824), so this plugin moves on its own and nothing else has to move with it.

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

`design` has its own `did_not_finish` carve-out (#1261) — the second of four independent answers to one question. It becomes `disposition: interrupted` and the bespoke path is deleted.

Coordinate with #1776: a failed design re-author deletes the previous valid `design.md`. Under #1829's `release` scope, a failing stage must leave its evidence on disk — that defect and this migration touch the same teardown path.

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

## ALSO LAND HERE — ADR-063 §1/§2 for `design` (from #2032)

**This migration is where the fix for #1833 belongs.** Do not do it before, and do
not do it separately.

Run [33548970231](https://github.com/ezigus/zBuild/actions/runs/33548970231) spent
three hours on #1833 and produced nothing: nine consecutive `design` calls killed at
the 600s ceiling, and **the ninth knew no more than the first**. Nothing ever told
the model there was a deadline, so it never wrote anything down before being cut off.

**What to add, alongside the v2 work:**

1. **Tell the model its limits**, sourced from the values that enforce them —
   `_route_resolve_timeout` (`core/router/route.sh:659`) and
   `_route_resolve_max_turns` (`:671`). Never a hand-copied number: a literal drifts
   from what actually kills the call, and then the prompt lies to the model with
   authority.
2. **Ask for a best-effort `design.md` before the cutoff**, with unfinished sections
   named rather than silently omitted.

**No new plumbing is needed.** `design` already refines a prior attempt rather than
restarting — `_design_read_prior_design` (`plugins/agent/design/plugin.sh:100`)
Tier 1 reads the previous iteration's body from the cycle feedback dir. That file is
a plain copy of the stage's declared output
(`core/pipeline/cycle-orchestrator.sh:1220`) and the copy runs whenever the cycle
continues (`:2727`) — it does **not** require the attempt to have succeeded. It has
simply never had a file to copy.

**Why it waits for this issue rather than landing sooner:** today a design that runs
out of time fails *loudly* — the run stops, nothing ships. A partial design is only
safe once a check can refuse one, and that check (ADR-063 §4) needs the v2
disposition field. Landing the partial without it would swap a loud failure for a
silent one: a half-finished design that looks complete, waved through, with
everything downstream built on it.

So: land §1/§2 **with** §3/§4 for this stage, in this issue.
