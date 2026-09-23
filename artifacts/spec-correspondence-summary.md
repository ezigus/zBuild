## spec-correspondence — partial

- judged 20 SPEC(s): 17 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-7 partial: The assertion confirms both "pass" and "error" appear in valid_verdicts but does not verify they are the only entries, so it does not establish that the declared list is exactly [pass, error].
- SPEC-10 partial: The assertion establishes rc=1 on missing manifest and that disabling `_security_lens_envelope_schema_ok` drops findings to zero, but never supplies an actual brace-bearing LLM response to verify the postamble recovery property specifically.
- SPEC-18 partial: The assertion establishes rc=130 and the correct v2 artifact shape on the router-rc=130 path, but does not verify that `_security_lens_interrupt_handler` exists as a named function and does not test direct handler invocation or kill -TERM.

