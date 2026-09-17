## spec-correspondence — partial

- judged 19 SPEC(s): 15 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion verifies that "verdict" appears *somewhere* in the `_review_lens_write_result` body (grep -q 'verdict') and that the coercion grep does not match that body, but it does not establish the requirement's constraint that verdict appears *only as a jq field* — a bare variable reference, comment, or other occurrence of the word "verdict" would satisfy the grep while violating the "jq field only" constraint.
- SPEC-11 partial: The first part establishes that the function exists, but the hardcoded-literal check uses a regex that only matches strings beginning with `lens-` or the literal `scope-manifest.md`; it would not catch other hardcoded artifact path literals (e.g. `"review-output.json"`, `/tmp/artifacts/...`), so a passing assertion establishes only that those two specific patterns are absent, not that the body contains no hardcoded artifact path literals generally.
- SPEC-12 partial: The grep checks for `primary: true` anywhere in `manifest.yaml`, so it would pass even if the flag appears on a different key — it does not establish that it is specifically `outputs[].lens_result` that declares `primary: true`.
- SPEC-18 partial: The assertion verifies that producer_stage, path, and type are absent and that id and required are present, but does not establish the "only" constraint — any other field not in the three-item exclusion list (e.g., `description`, `default`) could appear in an inputs entry and the assertion would still pass.

