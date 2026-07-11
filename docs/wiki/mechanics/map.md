# map

Fan a single **role** out over a **data-driven list**, running one instance per item. This is how zBuild expresses "do the same thing across N things" without naming each one in the template.

- **Shape:** a `map` group with a role and an `over:` list; the engine instantiates the role once per list item.
- **Canonical example:** `review_lenses` maps the `review_lens` role over `["security", "performance", "red-team", "correctness", "scope"]` — five lens runs from one declaration.
- **Aggregation:** map results are typically combined by an aggregator (see [[mechanics/aggregators]]); the review map is advisory.
- **Data-driven, not hardcoded (ADR-047):** the list is template data, so adding a lens or platform is a data change, not a mechanics change. This is also why per-mechanic auto-docs need a registry (#1356a) while per-leaf docs come from manifests.

See [[Pipeline-and-Stages]].
