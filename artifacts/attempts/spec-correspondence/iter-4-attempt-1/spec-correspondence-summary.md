## spec-correspondence — partial

- judged 8 SPEC(s): 6 correspond, 2 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-18 partial: The three path-specific checks and the static grep cover named explicit exit paths, but the static grep cannot detect cases where a command's own non-zero exit propagates through set -e or a subshell without an explicit exit/return statement, leaving the universal claim "all non-zero exits" unestablished.
- SPEC-20 partial: The grep on the extracted config block establishes the absence of a router block in the manifest, but the requirement also requires that manifest_router_knob returns empty string for timeout_s and max_turns, which the assertion never invokes or checks.

