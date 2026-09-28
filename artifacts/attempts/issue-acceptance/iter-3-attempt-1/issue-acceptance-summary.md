## issue-acceptance — fail

- SPEC-24 explicitly writes `disposition:out_of_turns` via "its own dedicated branch... intentionally not routed through router_reason_disposition," directly contradicting the issue's explicit instruction that out_of_turns and timed_out both be "named in one place, router_reason_disposition... Do not hand-write the word."

- NOT MET: turn-budget disposition (out_of_turns) sourced from router_reason_disposition rather than a hand-copied literal branch
