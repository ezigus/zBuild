## spec-correspondence — partial

- judged 14 SPEC(s): 8 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-6 partial: The grep searches for `result_contract: 2` anywhere in the manifest file, so it would pass even if that string appeared outside the `provides` section, not establishing that it is specifically declared under `provides.result_contract`.
- SPEC-7 partial: Grepping for `^\s*- pass` and `^\s*- error` as list items anywhere in the manifest would pass if those values appeared under a different key than `valid_verdicts`, so the assertion does not establish the required nesting.
- SPEC-10 partial: The assertion establishes the behavioral outcome of recovery (rc=0, file written, finding count=1) but does not verify that `_security_lens_envelope_schema_ok` is the mechanism responsible, leaving the named-function clause of the requirement unestablished.
- SPEC-11 partial: Grepping for `timeout_s:` and `max_turns:` anywhere in the manifest would pass if those keys appeared under a section other than `config.router`, so the assertion does not establish the required nesting.
- SPEC-12 partial: The stub `route_to_model` reads `$ZBUILD_ROUTER_MAX_TURNS_OVERRIDE` directly from the environment rather than receiving it from `_security_lens_run_inner`, so the assertion passes trivially whenever the env var is exported regardless of whether the plugin code actually forwards the override to the router.
- SPEC-13 partial: Grepping for `primary: true` anywhere in the manifest would pass even if that field appeared on a different output entry, so the assertion does not establish that it is declared specifically on the findings output.

