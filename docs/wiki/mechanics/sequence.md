# sequence

Run members **in order**, one after another. Each member sees the state produced by the previous one.

- **Shape:** an ordered list of members (leaves or nested operators).
- **Use it for:** ordered stages where later work depends on earlier output (e.g. `intake → plan`), or a multi-step refinement where each step builds on the last.
- **Failure:** if a member fails its gate, the sequence stops there (unless a [[mechanics/route_back]] or cycle wraps it).

Contrast with [[mechanics/parallel]] (concurrent, no ordering). See [[Pipeline-and-Stages]].
