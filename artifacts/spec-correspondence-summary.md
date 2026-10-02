## spec-correspondence — partial

- judged 20 SPEC(s): 14 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: The assertion only establishes that valid_verdicts is not the empty list `[]`; it does not verify the list is specifically `[pass, error]`, so any non-empty value would pass.
- SPEC-10 partial: The assertion establishes only the negative side — that the two hardcoded filename strings are absent — but does not verify that the inputs are resolved via ZBUILD_STAGE_INPUTS, which is the positive half of the requirement.
- SPEC-13 partial: The assertion only checks that no cleanup: entry exists; it does not verify that a run: pr_stage_run entry is present, which is the other half of the requirement.
- SPEC-17 partial: The assertion tests only the SIGTERM path; the requirement names both SIGTERM and SIGINT, so SIGINT handling is not established.
- SPEC-20 partial: The assertion checks for absence of the four explicitly named forbidden fields but does not verify that no other extraneous fields are present, so "declares only id and required:" is not fully established.
- SPEC-23 partial: The assertion verifies the forbidden pass-text is absent and that review_signal_missing is named, but does not directly verify that the summary affirmatively states no PR was opened, which is a distinct positive requirement.

