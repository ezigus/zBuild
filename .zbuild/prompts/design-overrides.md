# zBuild design-stage scope overrides

Per-repo overlay to the generic design charter's "enumerated set / absence-by-
omission" principle. The shipped engine states the principle; this file states
the **zBuild-specific** enumerations that break by OMISSION. Consult this when a
change grows, shrinks, or renames a closed set in this repository.

## Rule ABS-1 — the pipeline stage / agent-plugin set is an enumerated set

zBuild's pipeline stage list is a closed, exhaustively-enumerated set. Many
tests register the CURRENT full stage roster, or assert its exact COUNT. A
change that ADDS, REMOVES, or RENAMES a pipeline stage or agent plugin changes
that set, so every such enumeration is now wrong by omission — yet there is no
stale token to grep, because the breakage is the missing (or orphaned)
registration line.

When the change adds, removes, or renames a pipeline stage or agent plugin,
design MUST include in scope EVERY test that does any of the following:

1. Registers the stage roster via a mock-plugin helper, one call per stage:
   - `_make_plugin`          — wraps the shared factory; one call per stage.
   - `_make_role_plugin`     — role-based dispatch roster.
   - `_make_verdict_plugin`  — verdict-indicator roster.
   - `mock_plugin_factory`   — the shared factory in
     `scripts/lib/test-helpers.sh`; any test calling it directly.
   These appear as a vertical block of one-per-stage calls. A new stage not
   added to such a block makes that test register an incomplete pipeline, which
   then aborts at the first unregistered required stage (rc=5) — often BEFORE
   the test's own assertions print, so the failure looks like a silent abort.

2. Asserts a stage COUNT or a per-stage event count — any literal tied to the
   number of stages:
   - `stage.complete` event counts (e.g. "12 stage.complete events").
   - `started ` / `finished ` suffix counts (one line per stage).
   - `plugin.run.start` counts, including fanout multiples
     (stage_count × platform_count).
   Grepping the NEW count is impossible (it does not exist yet); grep the OLD
   count AND grep the enumeration helpers above, because some sites assert the
   count without echoing the number inline.

## Rule ABS-2 — config / golden enumerations of the same set

The stage set is also enumerated outside tests. When growing it, also rescope
any `config/templates/*.yaml` that lists stages and any `tests/golden/`
snapshot that pins the full event sequence — these break by omission
identically.

## How to find them

```
grep -rln '_make_plugin\|_make_role_plugin\|_make_verdict_plugin\|mock_plugin_factory' tests/
grep -rln 'stage\.complete\|plugin\.run\.start\|started .*UTC\|finished .*UTC' tests/
```

Every match that enumerates or counts the stage set belongs in the design scope
block. Do not trust any hardcoded list of sites to stay complete — re-run the
greps each time, because new enumeration sites are added with new tests.
