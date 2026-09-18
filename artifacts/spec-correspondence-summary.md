## spec-correspondence — partial

- judged 19 SPEC(s): 15 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-10 partial: The assertion verifies coercion tokens are absent from the files and from the `_review_lens_write_result` body, and that `verdict` appears somewhere in that body, but a bare `grep -q 'verdict'` passes whether `verdict` appears as a jq field, a shell variable, a comment, or any other form — the "only as a jq field" qualifier is not established.
- SPEC-11 partial: The assertion checks only for hardcoded paths matching `lens-[^$"]*` patterns and the specific literal `scope-manifest.md`, leaving other possible hardcoded artifact path literals (e.g., `"review-output.json"` or any non-`lens-`-prefixed filename) undetected, so passing it does not establish the full requirement.
- SPEC-12 partial: The assertion checks whether `primary: true` appears anywhere in `manifest.yaml`, but the requirement specifies it must be declared on `outputs[].lens_result` in particular — a `primary: true` on any other field would satisfy the grep while leaving the requirement unmet.
- SPEC-18 partial: The assertion confirms `id` and `required` are present and that the three named fields (`producer_stage`, `path`, `type`) are absent, but does not verify that no other undeclared fields exist in inputs entries, leaving the "declare only id and required" constraint incompletely established.

