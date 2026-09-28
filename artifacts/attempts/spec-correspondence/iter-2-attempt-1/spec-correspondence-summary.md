## spec-correspondence — partial

- judged 23 SPEC(s): 19 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-5 partial: The grep checks only that the string "Role: deploy_agent" appears somewhere in the file; it does not verify the line is a comment (prefixed with #) or that it is in the preamble position.
- SPEC-11 partial: The negative regex catches only two specific state-file-derived path patterns; other ways to construct such a path (e.g., string manipulation of state_file without matching those patterns) would not be caught, so a passing result does not fully establish "no state_file-derived path."
- SPEC-14 partial: The assertion verifies all three verdict values are exercised but does not check that each result also carries the v2 envelope fields (result_contract, disposition, reason) that the requirement specifies.
- SPEC-24 partial: The three grep calls verify each string is present somewhere in the manifest but do not establish that "router budgets: none" and "ADR-037 §3" appear together in the same comment documenting the router-budget absence, so the strings could satisfy the checks while being unrelated occurrences.

