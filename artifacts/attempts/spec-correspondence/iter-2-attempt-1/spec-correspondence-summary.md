## spec-correspondence — partial

- judged 20 SPEC(s): 18 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: The assertion establishes that valid_verdicts is not the empty list and has exactly two entries, but never checks that those two entries are specifically "pass" and "error" — any two other values would pass.
- SPEC-10 partial: The absence of the two hardcoded filename strings establishes the "no hardcoded constructions" clause, but a single reference count (>0) for ZBUILD_STAGE_INPUTS does not establish that those two specific inputs are resolved exclusively through it — the variable could be used for something else while the inputs arrive via a different mechanism not caught by the filename grep.

