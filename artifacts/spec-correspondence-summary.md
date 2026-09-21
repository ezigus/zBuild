## spec-correspondence — mismatch

- judged 15 SPEC(s): 6 correspond, 7 partial, 2 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: Calling `security_lens_cleanup` and checking rc=0 establishes the function-returns-0 clause, but `grep -q 'security_lens_cleanup'` matches a comment just as readily as a YAML key, so the declared-as-YAML-key clause is not established.
- SPEC-6 partial: `grep -q 'result_contract: 2'` matches the string anywhere in the manifest, so it would pass even if the field appeared outside the `provides:` section, leaving the specific nesting requirement unestablished.
- SPEC-7 partial: Grepping for `^\s*- pass` and `^\s*- error` matches those list items under any YAML key, so the assertion does not establish that they appear specifically under `valid_verdicts:`.
- SPEC-10 partial: The assertion establishes rc=1 on missing manifest and the behavioral outcome of recovery (rc=0, file written, finding count=1), but does not verify that `_security_lens_envelope_schema_ok` is the function responsible for the recovery.
- SPEC-11 partial: Grepping for `timeout_s:` and `max_turns:` anywhere in the manifest would pass if those keys appeared under a section other than `config.router`, so the required nesting is not established.
- SPEC-12 partial: The stub `route_to_model` reads `$ZBUILD_ROUTER_MAX_TURNS_OVERRIDE` directly from the environment, so the assertion passes trivially on any exported value regardless of whether `_security_lens_run_inner` actually forwards the override to the router.
- SPEC-13 partial: `grep -q 'primary: true'` matches anywhere in the manifest, so it would pass even if the field appeared on a different output entry, leaving the findings-output-specific nesting unestablished.
- SPEC-14 MISMATCH: The assertion uses `
- SPEC-15 MISMATCH: The assertion places `[SPEC-15]` inside `assert_pass`/`assert_fail` within an if/else block rather than in the required `assert_eq "[SPEC-15] …" "0" "$_spec15_rc"` form, so the acceptance-gate static grep cannot locate the tag and the assertion does not satisfy the stated structural requirement.

