## spec-coverage — uncovered

- SPEC-8/SPEC-9 check the prompt against the manifest's raw `config.router.*` value and SPEC-23/SPEC-24 check only the resulting disposition string, neither proving the issue's explicit "never a hand-copied literal — take it from `_route_resolve_timeout`/`_route_resolve_max_turns`/`router_reason_disposition`" requirement.

- NOT COVERED: budget-block numbers must reflect the router's resolved value (accounting for template override winning over manifest) via `_route_resolve_max_turns`/`_route_resolve_timeout`, not the raw manifest literal
- NOT COVERED: the `timed_out`/`out_of_turns` disposition values must be derived from `router_reason_disposition`, not hand-written strings.
