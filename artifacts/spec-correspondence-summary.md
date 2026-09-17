## spec-correspondence — partial

- judged 14 SPEC(s): 5 correspond, 9 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-3 partial: The assertion checks all three required output-file fields (result_contract=2, verdict=error, disposition=broken) but does not verify that the router-fatal path returns rc=1, which the requirement explicitly mandates.
- SPEC-4 partial: The assertion checks rc=1 and result_contract:2 but never reads or asserts the `verdict` field, so the requirement's `verdict=error` clause is not established.
- SPEC-6 partial: The grep checks for `result_contract: 2` anywhere in the manifest file but does not verify the value is nested under `provides`, so it would pass even if `result_contract: 2` appeared under a different top-level key.
- SPEC-7 partial: The greps confirm that the strings `- pass` and `- error` exist somewhere in the manifest file, but they do not scope the search to the `valid_verdicts` key under `config`, so the assertion passes even if those entries appear under a different key entirely.
- SPEC-10 partial: The assertion checks rc=0 and a non-empty findings count (both required), but the visible code does not inject postamble junk into the LLM response to actually trigger the recovery path — so whether `_security_lens_envelope_schema_ok` was invoked for recovery, rather than normal execution, is not established by what is shown.
- SPEC-11 partial: The assertion confirms both `timeout_s:` and `max_turns:` appear somewhere in the manifest file, but does not verify they reside under the `config.router` key as the requirement specifies — they could appear in any other section and the assertion would still pass.
- SPEC-12 partial: The assertion confirms that `ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=7` is visible inside `route_to_model` at call time, but never sets a conflicting `config.router.max_turns` in the manifest, so it cannot establish that the env var *takes precedence over* the manifest value — only that the env var is propagated.
- SPEC-13 partial: The grep confirms `primary: true` appears somewhere in the manifest file, but does not verify that the `primary: true` is specifically associated with the findings output — any other field or output carrying that flag would also pass the assertion.
- SPEC-14 partial: The regex `"[^"$]*\.(json|md)"` uses double-quote delimiters, so single-quoted literals like `'output.json'` or `'report.md'` — which are unambiguously bare hardcoded paths — are not matched, leaving that class of violation unchecked.

