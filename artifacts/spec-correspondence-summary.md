## spec-correspondence — mismatch

- judged 1 SPEC(s): 0 correspond, 0 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 MISMATCH: The requirement is about static manifest declarations (`result_contract:2` under `provides:` and a `config.router:` block with `timeout_s` and `max_turns`), while the assertion tests runtime behavior — exit code, LLM call count, and output report structure — none of which establish what the manifest file declares.

