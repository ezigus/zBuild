## spec-correspondence — partial

- judged 8 SPEC(s): 5 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The assertion covers three specific exit paths (missing input, probe rc=2 clamping, missing state file), but "all non-zero exits from plugin.sh" is a universal claim and the assertion cannot establish it holds for exit paths not exercised.
- SPEC-19 partial: The awk extraction establishes that valid_verdicts declares exactly [healthy, error] in the manifest, but the requirement also requires that validate-test.sh covers both verdicts via passing assertions, which the assertion does not check.
- SPEC-20 partial: The assertion establishes that the manifest contains no `config.router` block, but the requirement also claims `manifest_router_knob` returns empty strings for `timeout_s` and `max_turns` at runtime, which is not tested.

