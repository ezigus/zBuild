## spec-correspondence — mismatch

- judged 7 SPEC(s): 6 correspond, 0 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-24 MISMATCH: the requirement explicitly says this path is intentionally NOT routed through router_reason_disposition, but the assertion only checks the literal disposition/reason values and cannot distinguish a hand-copied literal from a router_reason_disposition call, so it doesn't establish (or refute) the routing mechanism the requirement asserts.

