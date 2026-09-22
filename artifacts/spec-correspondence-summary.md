## spec-correspondence — partial

- judged 20 SPEC(s): 18 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The missing-manifest rc=1 half is established, but the recovery sub-test feeds plain text with no brace-bearing postamble, so it does not exercise `_security_lens_envelope_schema_ok`'s specific recovery of that input shape.
- SPEC-18 partial: The assertion establishes rc=130 propagation and the artifact shape (verdict=error, disposition=interrupted, result_contract=2), but does not verify that `_security_lens_interrupt_handler` exists as a named function, nor test direct handler invocation or kill -TERM producing the same shape.

