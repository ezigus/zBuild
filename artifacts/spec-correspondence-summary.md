## spec-correspondence — partial

- judged 20 SPEC(s): 17 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The assertion checks the function is callable and returns 0, and checks no `cleanup:` key exists in the manifest hooks block, but does not verify the function is declared in `plugin.sh` specifically rather than a sourced helper.
- SPEC-10 partial: The missing-manifest rc=1 half is established, but the second half runs a plain text input without constructing a brace-bearing postamble, so it does not specifically exercise `_security_lens_envelope_schema_ok`'s recovery of that input shape.
- SPEC-18 partial: The assertion establishes the rc=130 path and the artifact shape (verdict=error, disposition=interrupted, result_contract=2), but does not verify that `_security_lens_interrupt_handler` exists as a named function, nor test direct handler invocation or kill -TERM producing the same shape.

