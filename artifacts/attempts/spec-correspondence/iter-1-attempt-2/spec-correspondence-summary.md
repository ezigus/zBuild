## spec-correspondence — partial

- judged 6 SPEC(s): 4 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-8 partial: The assertions establish the three value requirements (max_turns==45, timeout_s==600, max_turns>25) but cannot establish the structural requirement that the test uses an inline fixture rather than `load_template simple.yaml`.
- SPEC-9 partial: The assertion establishes count==19 and absence of release/persist, but the requirement also demands the explanatory comment be updated — which no assertion can verify.

