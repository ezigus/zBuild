# route_back

Send work **back to an earlier stage** when a later stage discovers the earlier one was wrong — without hardcoded jumps. (ADR-045)

- **What it does:** a stage can emit a route-back verdict (exit code 11) that re-enters an enclosing cycle at an earlier point, carrying feedback forward.
- **Canonical example:** in `simple.yaml`, the acceptance-gate can route back to `design_verify_cycle` when the implementation reveals a design-spec problem (verdict `route_design`), so design is revised before building continues.
- **Bounded:** route-back is governed by the enclosing [[mechanics/cycle]]'s iteration bound and stall detection, so it cannot loop forever.
- **Nested:** route-back composes with nested cycles (the engine targets the correct enclosing loop).

See [[mechanics/cycle]], [[mechanics/convergence]].
