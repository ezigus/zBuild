## spec-correspondence — partial

- judged 19 SPEC(s): 18 correspond, 1 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-12 partial: The awk triggers on any line containing "lens_result" rather than strictly on the `- id: lens_result` entry, so `primary: true` appearing in an earlier unrelated block that references lens_result would still satisfy the grep, meaning the assertion does not confirm the two properties belong to the same output entry.

