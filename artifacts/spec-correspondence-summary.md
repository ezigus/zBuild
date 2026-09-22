## spec-correspondence — partial

- judged 20 SPEC(s): 17 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion establishes that a missing scope manifest returns rc=1 and that postamble recovery produces a valid result, but never verifies that `_security_lens_envelope_schema_ok` is the specific function performing the recovery.
- SPEC-12 partial: The assertion confirms `--max-turns 7` appears in the captured argv and that the manifest carries a different value, but the snippet does not show the plugin run being executed with `ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=7` set, so the causal link between the env var and the override is not established.
- SPEC-18 partial: The assertion covers the rc=130 path and the resulting v2 artifact shape, but does not verify that `_security_lens_interrupt_handler` exists as a callable function, nor does it test direct handler invocation or `kill -TERM`.

