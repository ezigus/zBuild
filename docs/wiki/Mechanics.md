# Mechanics reference

zBuild's engine is a small, **closed set of operators** plus cross-cutting mechanics that every run relies on. Each is described on its own page so it can be documented — and, later, auto-regenerated (#1356) — individually.

## Operators (ADR-047)
The complete set. A template is a composition of these; there are no others.

| Operator | Purpose |
|---|---|
| [[mechanics/leaf]] | Run a single plugin (one stage). |
| [[mechanics/sequence]] | Run members in order, each seeing the previous output. |
| [[mechanics/parallel]] | Run members concurrently; join before continuing. |
| [[mechanics/cycle]] | Repeat members until an exit condition (bounded). |
| [[mechanics/map]] | Fan a role out over a data-driven list (e.g. review lenses). |

## Gating & convergence
| Mechanic | Purpose |
|---|---|
| [[mechanics/gates]] | `auto` vs blocking gates; verdicts that pass/fail a stage. |
| [[mechanics/convergence]] | `exit_when`, all/any conditions, `on_max` behavior for cycles. |
| [[mechanics/route_back]] | Send work to an earlier stage on failure (ADR-045). |
| [[mechanics/aggregators]] | Mechanical (gate-aggregator) vs advisory (review-aggregator) merges. |

## Cross-cutting mechanics
| Mechanic | Purpose |
|---|---|
| [[mechanics/redaction-chokepoint]] | The single path all model-bound text passes through (ADR-004). |
| [[mechanics/admission-gate]] | Fail-closed preconditions before a run starts. |
| [[mechanics/scope-governance]] | Read/write scope, security floor, governed expansion (ADR-030). |
| [[mechanics/state-and-resume]] | Atomic, crash-safe state; resume where a run stopped (ADR-006). |
| [[mechanics/event-bus]] | Schema-validated events (SQLite + JSONL). |
| [[mechanics/router-models-as-data]] | Tiered model routing from config, no model names in code (ADR-003). |
