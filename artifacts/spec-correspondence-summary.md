## spec-correspondence — partial

- judged 22 SPEC(s): 18 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-2 partial: It checks result_contract, disposition, and empty reason but never verifies that summary/checks live under data.* rather than top-level, which the requirement explicitly demands.
- SPEC-3 partial: It checks result_contract, disposition, unchanged verdict, and empty reason but never verifies data.summary/data.checks nesting, which the requirement explicitly demands.
- SPEC-5 partial: It checks disposition=unusable but never asserts the reason field is non-empty, which the requirement explicitly requires.
- SPEC-21 partial: It only exercises the router rc=10 path returning 1; it does not verify the SIGTERM/SIGINT path here or the general claim that rc is never outside {0,1}.

