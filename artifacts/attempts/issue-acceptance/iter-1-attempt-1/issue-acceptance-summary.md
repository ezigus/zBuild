## issue-acceptance — fail

- R-1's "fails at the merge-base" process claim cannot be verified from the diff alone — at the actual merge-base of this PR (after PR #2037 updated the ADR), SPEC-3's not-migrated branch would assert_pass for the wrong reason rather than fail; R-3's negative control depends on interpretation of "re-introducing" — SPEC-5 catches full migration reverts but not a bare call added alongside existing `_llm_envelope_parse`, and review-report has no absence-of-bare-call check at all.

- NOT SURE, a person must check: R-1: cannot confirm from the diff that SPEC-3 truly failed at the immediate merge-base (post-#2037, the ADR no longer matches `'All four Pattern-1 stages.*review'` so the not-migrated branch passes rather than fails)
- NOT SURE, a person must check: also cannot verify whether the PR body states the red step as CLAUDE.md requires
- NOT SURE, a person must check: R-3: SPEC-5 is a presence check for `_llm_envelope_parse` not an absence check for `extract_first_json_object` — if a bare call were added alongside `_llm_envelope_parse` in review-report, no test in the file would turn red
- NOT SURE, a person must check: the claim is met only under a "full-revert" interpretation of "re-introducing"
