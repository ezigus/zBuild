## spec-correspondence — partial

- judged 4 SPEC(s): 2 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion verifies draft=true in the output and --draft in gh args when state.status=failed, but never tests with _TPL_PR_DRAFT explicitly set to false, so the "regardless of _TPL_PR_DRAFT" clause of the requirement is not established.
- SPEC-3 partial: The requirement calls for the body to name "iterations_used/max" (both values), but the assertion only checks for the single literal "5", leaving the presence of both the iterations_used count and the max count unverified.

