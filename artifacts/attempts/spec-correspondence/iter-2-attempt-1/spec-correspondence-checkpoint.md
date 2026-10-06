# spec-correspondence checkpoint

## Files read
- design.md: confirms goal is to fix ADR-028 stale "not migrated" claims for review-lens/review-report, fix the comment-grep bug in adr-migration-claims-test.sh, and expand SPEC-2 loop. Two files changed: test file and ADR. SPEC-4 and SPEC-5 are [no-code]; SPEC-1 and SPEC-6 are [code].

## Conclusions per SPEC (final judgements)

SPEC-1: corresponds — assertion greps ADR for the `(review-lens|review-report).*\*\*not\*\*.*migrat` pattern, uses [#2035/SPEC-1] tag, fails when pattern found (current ADR), passes when absent (after replacement). Directly establishes the requirement.

SPEC-4: corresponds — assertion has two checks: (1) greps review-lens/plugin.sh with `^[^#]*extract_first_json_object` to verify the comment does not trigger (effect clause); (2) greps the test file (BASH_SOURCE[0]) for the literal string `grep -qE '^[^#]*extract_first_json_object' "$_rl"` to verify SPEC-3 uses this pattern (structural clause). The second check is not self-referential because SPEC-4's own code has `\"$_rl\"` (backslash-escaped) in the file while the search target has unescaped `"$_rl"`. Both clauses are covered.

SPEC-5: partial — assertion uses `_llm_envelope_(parse|classify)` while the requirement specifies `_llm_envelope_parse`; a directory with only `_llm_envelope_classify` would pass the assertion but not establish the requirement. The structural check verifies the `find -not -path` exclusion but not that the loop searches specifically for `_llm_envelope_parse`.

SPEC-6: partial — assertion uses awk to extract from `## Amendment v1.2` to end-of-file (not just the v1.2 section); if both names appeared in a later amendment section (v1.3+) but not in the v1.2 migration record, the assertion would pass but the requirement ("names … in its migration record") would not be met.

## Status: complete, all 4 verdicts reached.
