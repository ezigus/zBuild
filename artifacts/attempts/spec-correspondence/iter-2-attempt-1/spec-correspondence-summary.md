## spec-correspondence — partial

- judged 9 SPEC(s): 7 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-7 partial: The assertion checks only the specific patterns `disposition:.*exhausted` and `exhausted.*→.*escalate`, but the requirement forbids any prescriptive use of `exhausted` as the §3 disposition word or `escalate` as the §4 engine action, both of which could appear in other prose forms not matched by those patterns.
- SPEC-8 partial: The assertion verifies ≥2 distinct `_<stage>_budget_guidance` helpers appear in §1, but the requirement says each stage has its own helper; two helpers satisfies the count check while leaving undiscovered any stages the ADR discusses but does not pair with a helper.

