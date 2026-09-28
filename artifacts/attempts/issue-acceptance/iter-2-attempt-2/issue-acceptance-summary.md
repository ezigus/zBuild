## issue-acceptance — fail

- The issue's own words require both `out_of_turns` (turn budget) and `timed_out` (wall clock) to be "named in one place, router_reason_disposition" and never hand-written, but SPEC-24 instead commits the rc=10 path to a hand-copied literal pair via a dedicated branch "intentionally not routed through router_reason_disposition" — a SPEC that contradicts, not narrows, the requirement.

- NOT MET: rc=10 (turn-budget) disposition:out_of_turns must be derived from the router_reason_disposition chokepoint like the rc=124 path, not hand-written in a separate branch that bypasses it
