## spec-correspondence — partial

- judged 23 SPEC(s): 21 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-14 partial: The assertion verifies that all three verdict strings are present in the result files but does not check the v2 shape (result_contract, disposition, reason) for the `error` and `skipped` cases, leaving the "v2-shaped result" qualifier unestablished for those paths.
- SPEC-15 partial: The assertion verifies that `manifest_router_knob` returns empty for two specific keys, but a `config.router` block containing neither of those keys would also pass; the absence of the block itself is never checked.

