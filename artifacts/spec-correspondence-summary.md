## spec-correspondence — partial

- judged 20 SPEC(s): 19 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The assertion covers the rc=130 path and the resulting artifact shape (verdict=error, disposition=interrupted, result_contract=2), but does not check that `_security_lens_interrupt_handler` exists as a named function, nor that direct handler invocation or `kill -TERM` produce the same artifact shape.

