## spec-correspondence — partial

- judged 20 SPEC(s): 15 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The assertion confirms the function returns 0 and that a `cleanup: security_lens_cleanup` key exists somewhere in the manifest, but does not scope the grep to the `hooks:` section, so the "under hooks:" constraint is not established.
- SPEC-7 partial: The assertion confirms both `pass` and `error` appear in the `valid_verdicts:` list but does not verify the key is nested under `config:`, leaving the "under the config: section" constraint unestablished.
- SPEC-11 partial: The awk locates a `  router:` block anywhere in the manifest and confirms both `timeout_s:` and `max_turns:` are present, but does not verify the block is nested under `config:`.
- SPEC-12 partial: The mock reads `ZBUILD_ROUTER_MAX_TURNS_OVERRIDE` directly from the shell environment rather than from a parameter passed by the plugin, so the test confirms the env var persists through the call but does not establish that the plugin reads it and uses it as max_turns in place of the manifest value.
- SPEC-18 partial: The assertion covers the rc=130 path and the resulting v2 artifact shape, but does not verify that `_security_lens_interrupt_handler` exists as a callable function nor test direct handler invocation or `kill -TERM`, which the requirement also demands.

