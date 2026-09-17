## spec-correspondence — partial

- judged 14 SPEC(s): 9 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-6 partial: The assertion greps for the bare string `result_contract: 2` anywhere in the manifest file, so it does not establish that the field is declared under `provides` — a match in a different section or a comment would still cause `assert_pass`.
- SPEC-7 partial: The assertion confirms both `- pass` and `- error` appear in the manifest file, but it does not anchor them to the `valid_verdicts` key, nor does it verify that the list contains exactly those two values (a third verdict would still pass the assertion).
- SPEC-11 partial: The assertion confirms `timeout_s:` and `max_turns:` appear somewhere in the manifest, but does not check that they are nested under `config.router`, so the structural placement required by the spec is not established.
- SPEC-12 partial: The assertion confirms only that `ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=7` is visible inside `route_to_model` when propagated through `_security_lens_run_inner`, but never sets a conflicting `config.router.max_turns` in the manifest, so it does not establish that the env var takes *precedence over* the manifest value — the "overrides" half of the requirement is untested.
- SPEC-13 partial: The assertion greps for `primary: true` anywhere in the manifest file, establishing only that the flag appears somewhere — not that it is specifically declared on the findings output as the requirement states.

