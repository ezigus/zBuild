# gates

In plain terms: a gate is a **checkpoint**. After a step runs, the gate looks at the result and decides "pass" or "fail". If it fails, the pipeline stops (or retries, depending on the surrounding structure) rather than silently continuing with bad output.

A **gate** turns a stage's output into a pass/fail **verdict** that controls whether the pipeline proceeds.

- **`gate: auto`** — the engine reads the stage's structured verdict automatically (the common case).
- **Blocking vs advisory** — mechanical gates (e.g. `design-gate`, `gate-aggregator`, `secret-scan`, `shape-floor`, `coverage-gate`) can block progression; advisory stages (the review lenses) report findings but never block a merge. The **gate-aggregator is the sole merge-blocker** in `simple.yaml`.
- **Verdicts** — gates emit a verdict (e.g. `pass` / `fail`, sometimes richer like `route_design`); cycles use these as their [[mechanics/convergence]] exit conditions.
- **Blocking gates (ADR-013/031)** — a required gate that fails halts the run rather than silently continuing.

See [[mechanics/aggregators]], [[mechanics/convergence]], and the per-gate pages under [[Plugins]] (e.g. [[plugins/gate-aggregator]], [[plugins/design-gate]]).
