## spec-correspondence — partial

- judged 20 SPEC(s): 18 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion establishes rc=1 on missing manifest and that disabling `_security_lens_envelope_schema_ok` drops findings to zero, but does not test with an actual brace-bearing LLM response, so the specific "brace-bearing postamble" property is not established.
- SPEC-18 partial: The assertion establishes rc=130 and the correct v2 artifact shape on the router-rc=130 path, but does not check that `_security_lens_interrupt_handler` exists as a named function and does not test direct handler invocation or kill -TERM.

