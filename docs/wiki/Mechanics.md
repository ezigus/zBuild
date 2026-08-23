# Mechanics reference

In plain terms: a **mechanic** (or **operator**) is a rule the engine follows to run your pipeline — things like "run these steps in order", "retry until the tests pass", or "block if secrets are found". You'd look here when you want to understand *why* the pipeline behaves a certain way, or when you're writing a template and need to pick the right building block.

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
| [[mechanics/vision-document]] | Required repo vision: location, format, word cap, and validator (ADR-049). |
| [[mechanics/stage-io]] | Per-stage INPUT/OUTPUT banners; persona: field; ZBUILD_STAGE_IO_FD (ADR-015). |
| [[mechanics/write-boundary]] | The five areas a stage may write into, incl. per-stage scratch and run bookkeeping (ADR-058). |
