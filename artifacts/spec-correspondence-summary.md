## spec-correspondence — partial

- judged 4 SPEC(s): 1 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-4 partial: The assertion verifies the effect—that `^[^#]*extract_first_json_object` finds no non-comment occurrences in plugin.sh—but does not verify the structural half of the requirement: that adr-migration-claims-test.sh's SPEC-3 grep was actually changed to use that comment-excluding pattern.
- SPEC-5 partial: The assertion greps for `_llm_envelope_(parse
- SPEC-6 partial: The assertion checks for both names anywhere in the ADR file, but the requirement says "in its migration record"; passing the assertion would not distinguish names added to the migration record from names added to any other section of the file.

