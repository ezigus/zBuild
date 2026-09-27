## spec-correspondence — partial

- judged 8 SPEC(s): 6 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The three path-specific runtime checks and the static grep cover named explicit exit/return statements, but the grep cannot detect non-zero exits that propagate implicitly through set -e without an explicit exit/return statement, leaving the universal claim "all non-zero exits" unestablished.
- SPEC-20 partial: The assertion establishes the absence of a router block in the manifest but never invokes manifest_router_knob to verify it returns empty string for timeout_s and max_turns.

