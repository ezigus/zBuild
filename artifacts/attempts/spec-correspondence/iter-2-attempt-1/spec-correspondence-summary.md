## spec-correspondence — partial

- judged 9 SPEC(s): 7 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The multi-lens failure case (_RR_FAIL_ALL_RC=1) uses the same rc=1 for all lenses, so "disposition from the first failed lens rc" is never distinguished from any other lens's rc — the ordering semantics the requirement specifies are not established.
- SPEC-8 partial: Checking that the count of distinct _<stage>_budget_guidance helpers is greater than 1 shows multiple helpers exist but does not establish that every stage has its own, which is what "each stage has its own" requires.

