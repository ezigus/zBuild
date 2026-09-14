## spec-correspondence — partial

- judged 1 SPEC(s): 0 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The three `grep -q` checks confirm the required strings appear somewhere in the manifest file, but the requirement demands structural placement — `result_contract:2` specifically under `provides:` and `timeout_s`/`max_turns` specifically inside a `config.router:` block — neither of which a flat string search establishes.

