## spec-correspondence — partial

- judged 23 SPEC(s): 18 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-13 partial: The static grep catches only literal `exit/return N` (N in 2–9) and would miss dynamic exit codes like `exit $rc`; the four runtime checks add specific paths but cannot establish "all error exit paths" without knowing the complete set.
- SPEC-14 partial: All three verdict values are exercised, but the assertion only checks the `verdict` field and never verifies the v2 shape (result_contract, disposition, reason), which the requirement explicitly requires.
- SPEC-18 partial: The assertion confirms `run:` key exists and `cleanup:` is absent, but never checks that the value is specifically `deploy_agent_run`, which the requirement explicitly states.
- SPEC-19 partial: `disposition=complete` and a non-empty `reason` are verified, but `verdict=deployed` — which the requirement explicitly lists as one of the three required fields — is not checked in this assertion.
- SPEC-24 partial: The presence of `router budgets: none` and `ADR-037` are both verified, but the requirement specifically requires the reference to include `§3`, and the assertion does not check for that.

