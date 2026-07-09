# zBuild design-stage scope overrides

Per-repo overlay to the generic design charter's "enumerated set / absence-by-
omission" principle (ADR-032/033). The shipped engine states the principle; this
file states this repo's genuine domain-specific enumerations that break by
OMISSION. Consult this when a change grows, shrinks, or renames a closed set in
this repository.

> **ADR-047 tombstone (EPIC #1277 / #1282).** zBuild's pipeline stage set is NO
> LONGER a closed, engine-owned vocabulary. `_ZBUILD_CANONICAL_STAGES` was
> demoted (ADR-047 §5): stage membership is now a manifest-derived, fail-closed
> resolvability preflight and stage ordering a data-dependency DAG — both keyed
> on declared data, not a hardcoded roster. The former Rules ABS-1/ABS-2/ABS-3
> here enumerated that now-open roster and are retired. What remains below is the
> **generic** principle only (it names no stage), plus this repo's real closed
> sets. A change that adds/removes/renames a pipeline stage is now a template +
> plugin change; it no longer breaks an engine-owned roster enumeration.

## Rule ABS — generic enumerated-set / absence-by-omission wisdom

Some closed sets in this repo break by OMISSION rather than by a stale token you
can grep: the breakage is a MISSING (or orphaned) line, not a changed one. When a
change grows, shrinks, or renames such a set, every enumeration of that set is
wrong by omission — yet there is nothing to grep for, because the defect is the
absent entry.

When a change touches a genuinely-closed, exhaustively-enumerated set in this
repo, design MUST include in scope every test or config that enumerates or COUNTS
that set. Because the breakage is an absence, do not trust a hardcoded list of
sites to stay complete — rediscover the sites each time (see "How to find them").

This principle is target-agnostic: it applies to any closed set, and it does not
presume the pipeline stage set is closed (per the ADR-047 tombstone above, it is
not). Use it for sets that are genuinely closed in this repo, declared here per
ADR-032 as this repo's domain-specific enumerations.

## How to find them

Enumeration/count sites are most often mock-plugin roster blocks (one call per
member) or literal counts of the set. Rediscover them with:

```
grep -rln '_make_plugin\|_make_role_plugin\|_make_verdict_plugin\|mock_plugin_factory' tests/
grep -rln 'stage\.complete\|plugin\.run\.start\|started .*UTC\|finished .*UTC' tests/
```

Every match that enumerates or counts a closed set you are changing belongs in
the design scope block. Re-run the greps each time — new enumeration sites arrive
with new tests, and the defect (a missing line) leaves no token to search for.
