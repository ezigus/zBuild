## spec-correspondence — partial

- judged 1 SPEC(s): 0 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The three `grep -q` checks confirm the strings `result_contract: 2`, `timeout_s:`, and `max_turns:` appear somewhere in the manifest, but none of them verify structural placement — the requirement demands `result_contract:2` sit specifically **under `provides:`** and that `timeout_s` and `max_turns` sit specifically **inside a `config.router:` block**, neither of which a flat grep establishes.

