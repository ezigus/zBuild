## spec-correspondence — partial

- judged 19 SPEC(s): 13 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-9 partial: The assertion verifies all four v1 fields are present and checks score and name values are unmodified, but for findings[] it only asserts count (== 1) rather than content — if the plugin mutated finding fields (file, severity, message, etc.) the assertions would still pass, leaving the "unmodified" claim for findings[] partially established.
- SPEC-10 partial: The assertion fully establishes that the coercion tokens are absent from both source files and that the coercion grep does not false-positive in the write_result body, but `grep -q 'verdict'` merely confirms the string "verdict" appears somewhere in that body — it does not establish that verdict appears specifically *as a jq field*, so the "only as a jq field" qualifier in the requirement is unverified.
- SPEC-11 partial: The assertion checks only for hardcoded path literals matching specific patterns (`lens-*` prefixed strings and `"scope-manifest.md"`), so it would pass silently if the body contained other hardcoded artifact path literals that do not match those patterns.
- SPEC-12 partial: The assertion checks whether `primary: true` appears anywhere in the manifest file, not specifically within the `outputs[].lens_result` entry — a manifest where another output carries `primary: true` would pass the assertion without satisfying the requirement.
- SPEC-16 partial: The assertion extracts the entire `provides:` block (not specifically the `provides.events` sub-key) and counts `review_lens.` occurrences within that broader section, so it establishes presence and exact count of the three named events somewhere inside `provides:` but does not verify they are structurally declared under the `events:` sub-key specifically.
- SPEC-18 partial: The assertion confirms the three named forbidden fields are absent and that `id` and `required` are present, but it does not enforce the "only" constraint — an inputs entry carrying additional fields beyond `id` and `required` (e.g., `description`, `default`) would pass all checks while still violating the requirement.

