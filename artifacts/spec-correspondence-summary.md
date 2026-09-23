## spec-correspondence — partial

- judged 20 SPEC(s): 18 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion verifies rc=1 on missing-manifest and confirms `_security_lens_envelope_schema_ok` exists plus that recovery succeeds, but does not establish that recovery is specifically performed by that function rather than some other code path.
- SPEC-18 partial: The assertion covers rc=130, verdict=error, disposition=interrupted, and result_contract=2 on the router-rc=130 path, but does not check that `_security_lens_interrupt_handler` exists nor that direct handler invocation or kill -TERM produce the same artifact shape, leaving two of the requirement's named properties unestablished.

