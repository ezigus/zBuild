## spec-correspondence — unjudged

- judged 19 SPEC(s): 14 correspond, 4 partial, 0 mismatch, 0 uncheckable, 1 unjudged

- SPEC-4 UNJUDGED (no parseable verdict in the reply)
- SPEC-10 partial: The assertion confirms `"verdict"` (double-quoted) appears somewhere in the `_review_lens_write_result` body and that the coercion grep does not false-positive on it, but the "only as a jq field" qualifier is unverified — verdict appearing as a quoted string in a comment, echo, or variable assignment would satisfy the grep while violating the requirement.
- SPEC-11 partial: The two regex patterns catch quoted strings ending in `.json|md|patch|yaml|sh` and several named artifact filenames, but a hardcoded path literal using any other extension (e.g. `.txt`, `.xml`) or enclosed in single quotes would pass both greps undetected, leaving the "no hardcoded artifact path literals" claim only partially established.
- SPEC-12 partial: The assertion confirms `primary: true` appears within a 10-line window after the `lens_result` line inside the outputs block, but a sibling output entry that begins within those 10 lines and carries `primary: true` would pass the check while the `lens_result` entry itself lacks the declaration.
- SPEC-16 partial: The assertion confirms all three named events appear in the extracted events sub-block and checks that exactly 3 lines match `review_lens\.`, but the count uses `grep -c 'review_lens\.'` rather than counting all entries — an additional event without the `review_lens.` prefix would pass the count check undetected, leaving the "exactly three total" claim unestablished.

