## spec-correspondence — partial

- judged 8 SPEC(s): 5 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The assertion checks three specific exit paths (missing input, probe rc=2 clamped, missing state_file), but the requirement says "all non-zero exits" — paths not enumerated in the test (e.g., missing health-check binary) remain unverified.
- SPEC-19 partial: The assertion checks only that the manifest declares exactly `[healthy, error]`; the second clause — that validate-test.sh contains at least one passing assertion for each verdict — is not verified by the assertion.
- SPEC-20 partial: The assertion checks that no `router:` key appears in the manifest's config block, but the requirement also names `manifest_router_knob` returning empty for `timeout_s` and `max_turns` as something to verify, and the assertion does not invoke or inspect that function.

