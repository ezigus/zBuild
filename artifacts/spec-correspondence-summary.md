## spec-correspondence — partial

- judged 20 SPEC(s): 18 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion establishes rc=1 on missing manifest and that postamble recovery produces a valid artifact, but only checks that `_security_lens_envelope_schema_ok` exists — it does not establish that recovery is performed by that function rather than another code path.
- SPEC-18 partial: The assertion establishes rc=130 and the correct artifact shape on the router-rc=130 path, but does not check that `_security_lens_interrupt_handler` exists as a named function, and does not test direct handler invocation or kill -TERM, leaving two of the requirement's named properties unestablished.

