# cycle

Repeat members **until an exit condition is met** — a bounded loop. This is how zBuild converges work (e.g. build → test → fix → re-test until gates pass).

- **Shape:** a list of members plus a convergence spec (see [[mechanics/convergence]]): `exit_when` conditions (all/any), a max-iteration bound, and an `on_max` behavior.
- **Bounded:** cycles always have a maximum iteration count; on reaching it, `on_max` decides whether to continue (fall through) or fail.
- **Examples in `simple.yaml`:** `design_verify_cycle` (design → design-gate) and `build_test_cycle` (build → test → gates → gate-aggregator).
- **Route-back:** a cycle can be re-entered from a later stage via [[mechanics/route_back]] (ADR-045).

See [[mechanics/convergence]] and [[Pipeline-and-Stages]].
