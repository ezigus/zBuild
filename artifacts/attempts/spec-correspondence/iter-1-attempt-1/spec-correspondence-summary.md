## spec-correspondence — partial

- judged 15 SPEC(s): 8 correspond, 7 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertions cover no-goal, empty-goal, empty-after-sanitization, missing-state-file, failed-fetch, and all closed-issue variants, but "branch refused" — explicitly named in the requirement — has no corresponding rc=1 assertion.
- SPEC-2 partial: intake-result.json existence is verified for no-goal, success, empty-after-sanitization, missing-state-file, empty-goal, failed-fetch, and T_456_a, but the closed-issue variants T_456_b through T_456_j and the subprocess test have no assert_file_exists, leaving several failure modes unchecked.
- SPEC-3 partial: The assertion checks that disposition is non-empty but not that it belongs to the engine's vocabulary, so a well-formed JSON with an arbitrary disposition string would satisfy all three checks.
- SPEC-5 partial: The assertion confirms valid_verdicts contains "pass" and "fail" and is not empty, but does not rule out additional values, so a list like [pass, fail, warn] would pass all checks while not matching the exact declared value.
- SPEC-11 partial: The assertion greps the entire manifest.yaml for the comment text but does not verify the comment resides in the hooks section specifically, so the text appearing elsewhere in the file would satisfy the check while not meeting the placement requirement.
- SPEC-13 partial: The assertion counts all lines in manifest.yaml matching "intake\." rather than counting events specifically within the provides.events list, so unrelated occurrences of that pattern can inflate the count, and no specific event names are checked, leaving silent drops undetected.
- SPEC-15 partial: The assertion checks that data.goal_len and data.platform_count are integers but does not verify they are semantically correct (i.e., that goal_len equals the character count of the sanitized goal and platform_count equals the number of detected platforms).

