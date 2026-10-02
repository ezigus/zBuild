## spec-correspondence — partial

- judged 7 SPEC(s): 6 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The assertion establishes that a single failing lens produces a disposition from router_reason_disposition rather than hardcoded "complete", but it does not exercise the "worst failed lens rc" selection because only one lens fails — the priority-ordering logic across multiple simultaneous lens failures is untested.

