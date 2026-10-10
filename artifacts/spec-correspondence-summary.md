## spec-correspondence — partial

- judged 4 SPEC(s): 3 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: The assertions establish count=19 and the shifted indices for shape-floor (10) and gate-aggregator (15), but none of the three shown assertions directly verifies that `impact` is absent from `_TPL_STAGES` — a 19-element array where a different stage was removed and impact inserted elsewhere would still pass all three.

