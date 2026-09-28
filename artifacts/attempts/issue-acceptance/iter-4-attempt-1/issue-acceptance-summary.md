## issue-acceptance — fail

- ALSO LAND HERE requires both out_of_turns and timed_out to be sourced from the single router_reason_disposition chokepoint ("both named in one place... do not hand-write the word"), but SPEC-24 explicitly commits the turn-budget path to a hand-copied literal pair "intentionally not routed through router_reason_disposition."

- NOT MET: disposition:out_of_turns/reason:budget_exhausted must come from router_reason_disposition, not a hardcoded literal, per the issue's ALSO LAND HERE section
