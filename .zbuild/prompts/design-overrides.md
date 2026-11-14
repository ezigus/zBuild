# zBuild design-stage overrides

This repository's own additions to design's job (ADR-032/033): the sets in this
repository that break by OMISSION, and how a design accounts for them.

## Rule ABS — a closed set breaks by omission

Some closed sets in this repo break by OMISSION rather than by a stale token you
can grep: the breakage is a MISSING (or orphaned) line, not a changed one. When a
change grows, shrinks, or renames such a set, every enumeration of that set is
wrong by omission — yet there is nothing to grep for, because the defect is the
absent entry. The pipeline's stages are not such a set: which stages run is
template data, not a list the code enumerates.

When a change grows, shrinks or renames a closed set, the design accounts for
every place that enumerates or COUNTS it:

- code or config that enumerates it: a step, naming that code;
- an existing test that enumerates or counts it: a line in the ```supersedes
  block (the test file, the assertion's tag, and why it is now wrong), so the
  test author brings it up to the new set.

Rediscover the places each time; a hardcoded list of them goes stale.

## How to find them

Enumeration/count sites are most often mock-plugin roster blocks (one call per
member) or literal counts of the set. Rediscover them with:

```
grep -rln '_make_plugin\|_make_role_plugin\|_make_verdict_plugin\|mock_plugin_factory' tests/
grep -rln 'stage\.complete\|plugin\.run\.start\|started .*UTC\|finished .*UTC' tests/
```

Re-run the greps each time — new enumeration sites arrive with new tests, and
the defect (a missing line) leaves no token to search for.

## Rule ABS-W — a new plugin directory needs a wiki page

A change that creates `plugins/<kind>/<id>/manifest.yaml` also creates
`docs/wiki/plugins/<id>.md`, with a prose opening paragraph: a step names it,
and a `[doc]` SPEC says what it must tell a reader. The `lint-doc-freshness`
gate (`scripts/lib/lint-doc-freshness.sh`) fails the suite when the page is
absent or has no opening paragraph — there is no old value to grep for, because
the defect is the missing new file.

**Exception — `kind: persona` plugins:** persona manifests are data-only (no
`plugin.sh`, no hooks) and share one page, `docs/wiki/plugins/personas.md`. A new
persona adds its id there instead of a page of its own; `lint-doc-freshness`
checks that every persona id appears in that page, and a per-id persona page is
an orphan it fails.
