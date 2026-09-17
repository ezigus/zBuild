## spec-correspondence — partial

- judged 19 SPEC(s): 13 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion confirms "verdict" appears *somewhere* in the `_review_lens_write_result` body and that the coercion grep does not match that body, but does not establish the "only as a jq field" constraint — a bare variable reference, comment, or other non-jq occurrence of the word "verdict" would satisfy `grep -q 'verdict'` while violating the requirement.
- SPEC-11 partial: The existence check is fully established, but the hardcoded-literal regex only matches strings starting with `lens-` or the literal `scope-manifest.md`; other hardcoded artifact path literals (e.g., `"review-output.json"`, `/tmp/artifacts/...`) would pass unchallenged, so the assertion establishes only that those two specific patterns are absent, not that the body contains no hardcoded artifact path literals generally.
- SPEC-12 partial: The grep confirms `primary: true` appears somewhere in `manifest.yaml` but does not establish that it is specifically `outputs[].lens_result` that carries the flag — any other key bearing `primary: true` would satisfy the assertion while leaving the requirement unmet.
- SPEC-16 partial: The assertion confirms all three named events are present and that exactly three `review_lens.`-prefixed lines appear in the provides section, but does not establish that no additional events with a different prefix exist in that section, so the "exactly three" constraint is not fully established.
- SPEC-18 partial: The assertion verifies that the three named forbidden fields are absent and that id and required are present, but does not establish the "only" constraint — any other undeclared field (e.g., `description`, `default`) could appear in an inputs entry and all checks would still pass.
- SPEC-19 partial: The assertion checks both the absence of `cleanup:` and the presence of the ADR-054 §7 citation, but does not verify the citation appears in a YAML comment — a match in a field value rather than a `#`-prefixed comment line satisfies the grep while failing the requirement's "explanatory comment" constraint.

