## spec-correspondence — partial

- judged 20 SPEC(s): 17 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The assertion only calls security_lens_cleanup and checks it returns 0; it does not verify the hook is declared as a YAML key under hooks: in the manifest rather than merely as a comment.
- SPEC-10 partial: The missing-manifest rc=1 half is established, but the second half runs a plain text input and checks for one finding without constructing or confirming a brace-bearing postamble scenario that specifically exercises _security_lens_envelope_schema_ok.
- SPEC-18 partial: The assertion establishes the rc=130 path and resulting artifact shape, but does not check that _security_lens_interrupt_handler exists as a named function, nor test direct handler invocation or kill -TERM producing the same shape.

